//! ETHA's TAS registers and indirect gate-list RAM.
//!
//! Learn and read operations complete at the bus boundary. The RAM address
//! register selects one of 256 entries; the data word carries gate time and
//! gate state.
//!
//! EATASCTM (TASOCT) reports the cycle time of the ongoing schedule, not the
//! configured one (HUM 32.5.1.6). EATASCTC is copied into it when the
//! schedule is taken into operation: when TASE is set, or TASCC asks for a
//! change, while the agent is in OPERATION, or when the agent enters
//! OPERATION with TASE already set. In CONFIG mode nothing runs, so the
//! monitor stays 0; the EK-RA8D2 reads tas_cycle=0 there (RA8EMU-496).
//! Clearing TASE or entering RESET clears it. A configuration change
//! completes at once: the start-time wait is not modelled.
const lanes = @import("../lanes.zig");
const eth_mode = @import("mode.zig");

pub const reg = struct {
    pub const start: u32 = 0x0300;
    pub const config: u32 = 0x0300;
    pub const initial_gates: u32 = 0x0304;
    pub const entry_counts: u32 = 0x0320;
    pub const cycle_start_low: u32 = 0x03a0;
    pub const cycle_start_high: u32 = 0x03a4;
    pub const cycle_start_monitor_low: u32 = 0x03a8;
    pub const cycle_start_monitor_high: u32 = 0x03ac;
    pub const cycle_time: u32 = 0x03b0;
    pub const cycle_monitor: u32 = 0x03b4;
    pub const learn_address: u32 = 0x03c0;
    pub const learn_data: u32 = 0x03c4;
    pub const learn_status: u32 = 0x03c8;
    pub const read_address: u32 = 0x03d0;
    pub const read_result: u32 = 0x03d4;
    pub const ram_init: u32 = 0x03e4;
    pub const end: u32 = 0x03ec;
    pub const span: u32 = end - start;
    pub const ram_entries: usize = 256;
    pub const gate_time_mask: u32 = 0x0fff_ffff;
    pub const gate_state: u32 = 1 << 28;
    pub const busy: u32 = 1 << 31;
    pub const ram_init_request: u32 = 1;
    pub const ram_ready: u32 = 1 << 1;
    pub const tas_enable: u32 = 1;
    const config_change: u32 = 1 << 1;
    const config_impossible: u32 = 1 << 2;
    const timer_select: u32 = 1 << 8;
};

const word_count = reg.span / 4;

/// Registers and gate RAM for one ETHA port.
pub const Tas = struct {
    base: u32,
    words: [word_count]u32 = @splat(0),
    ram: [reg.ram_entries]u32 = @splat(0),
    writes: u32 = 0,
    resets: u32 = 0,
    learns: u32 = 0,
    reads: u32 = 0,
    /// Whether the agent is in OPERATION, the only mode the scheduler runs.
    operating: bool = false,
    /// TASOCT: the cycle time the ongoing schedule took into operation.
    oper_cycle: u32 = 0,

    pub fn init(base: u32) Tas {
        return .{ .base = base };
    }

    pub fn read(self: *Tas, address: u32, width: u3) u32 {
        const relative = address -% self.base;
        const offset = lanes.word(relative);
        const whole = switch (offset) {
            reg.cycle_monitor => self.cycleMonitor(),
            reg.learn_status, reg.read_result => self.word(offset) & ~reg.busy,
            reg.ram_init => self.word(offset) | if (self.resets == 0) 0 else reg.ram_ready,
            else => self.word(offset),
        };
        return lanes.part(whole, lanes.lane(relative), width);
    }

    pub fn write(self: *Tas, address: u32, width: u3, value: u32) void {
        self.writes +%= 1;
        const relative = address -% self.base;
        const offset = lanes.word(relative);
        const asked = lanes.merge(self.word(offset), lanes.lane(relative), width, value);
        switch (offset) {
            reg.learn_address => self.setWord(offset, asked & 0xff),
            reg.learn_data => self.learn(asked),
            reg.read_address => self.readEntry(asked & 0xff),
            reg.ram_init => self.resetRam(asked),
            reg.config => self.setConfig(asked),
            else => self.setWord(offset, asked),
        }
    }

    pub fn quiet(self: *const Tas) bool {
        return self.writes == 0 and self.resets == 0 and self.learns == 0 and self.reads == 0;
    }

    fn word(self: *const Tas, offset: u32) u32 {
        return self.words[(offset - reg.start) / 4];
    }

    fn setWord(self: *Tas, offset: u32, value: u32) void {
        self.words[(offset - reg.start) / 4] = value;
    }

    fn learn(self: *Tas, value: u32) void {
        const address = self.word(reg.learn_address) & 0xff;
        const entry = value & (reg.gate_time_mask | reg.gate_state);
        self.ram[address] = entry;
        self.setWord(reg.learn_data, entry);
        self.setWord(reg.learn_status, 0);
        self.learns +%= 1;
    }

    fn readEntry(self: *Tas, address: u32) void {
        self.setWord(reg.read_address, address);
        self.setWord(reg.read_result, self.ram[address]);
        self.reads +%= 1;
    }

    fn resetRam(self: *Tas, value: u32) void {
        if (value & reg.ram_init_request == 0) {
            self.setWord(reg.ram_init, value & ~reg.ram_ready);
            return;
        }
        self.ram = @as([reg.ram_entries]u32, @splat(0));
        self.setWord(reg.ram_init, reg.ram_ready);
        self.resets +%= 1;
    }

    /// The agent's mode machine moved to `mode`.
    pub fn enterMode(self: *Tas, mode: eth_mode.Mode) void {
        const was = self.operating;
        self.operating = mode == .operation;
        if (mode == .reset) {
            self.setWord(reg.config, self.word(reg.config) & ~reg.tas_enable);
            self.oper_cycle = 0;
        }
        if (self.operating and !was and self.enabled()) self.apply();
    }

    fn setConfig(self: *Tas, value: u32) void {
        const was = self.enabled();
        const writable = reg.tas_enable | reg.timer_select;
        self.setWord(reg.config, value & writable & ~(reg.config_change | reg.config_impossible));
        if (!self.enabled()) {
            self.oper_cycle = 0;
            return;
        }
        if (!was or value & reg.config_change != 0) self.apply();
    }

    fn enabled(self: *const Tas) bool {
        return self.word(reg.config) & reg.tas_enable != 0;
    }

    /// Take the configured cycle into operation, if the scheduler runs.
    fn apply(self: *Tas) void {
        if (self.operating) self.oper_cycle = self.word(reg.cycle_time);
    }

    fn cycleMonitor(self: *const Tas) u32 {
        return self.oper_cycle;
    }
};
