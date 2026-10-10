//! The MAX17048-class fuel gauge on the carrier's I2C line, 7-bit address
//! 0x36, and the battery state the run gives it.
//!
//! The part is a file of big-endian sixteen-bit registers behind a byte
//! pointer: a transfer names a register, then a word goes down high byte
//! first or a word comes back. A battery monitor reads VCELL, SOC and CRATE
//! and reports a percentage and a direction from them.
//!
//! dev carried this as a flat 256-byte file that took a byte anywhere, so a
//! driver could store its own state-of-charge over the gauge's and read the
//! number back as a measurement, a read starting on an odd address handed
//! back half of one register and half of the next, and the power-on-reset
//! command landed in the file and did nothing at all.
const bus = @import("ra8_chip").periph.riic.bus;

pub const address: u7 = 0x36;

/// The registers this part has, and the end of the mapped word space
/// (MAX17048/MAX17049 datasheet Rev 4, Table 2).
pub const reg = struct {
    pub const vcell: u8 = 0x02;
    pub const soc: u8 = 0x04;
    pub const mode: u8 = 0x06;
    pub const version: u8 = 0x08;
    pub const hibrt: u8 = 0x0A;
    pub const config: u8 = 0x0C;
    pub const valrt: u8 = 0x14;
    pub const crate: u8 = 0x16;
    pub const vreset: u8 = 0x18;
    pub const status: u8 = 0x1A;
    pub const command: u8 = 0xFE;
    pub const count: usize = 0x1C;
    pub const word_bytes: usize = 2;
};

/// What the gauge reports about the cell. The voltage, the version and the
/// charge-rate magnitude are dev's own values carried over; the datasheet
/// fixes only their units (VCELL 78.125 uV/LSB, SOC's high byte the integer
/// percent, CRATE signed at 0.208 %/hr).
pub const cell = struct {
    pub const default_soc: u8 = 72;
    pub const full: u8 = 100;
    pub const vcell: u16 = 0xBE00;
    pub const version: u16 = 0x0012;
    pub const crate_magnitude: i16 = 0x0018;
    pub const percent_shift: u4 = 8;
};

/// The word a driver puts in CMD to power-on-reset the gauge.
pub const power_on_reset: u16 = 0x5400;

pub const Error = error{SocOutOfRange};

/// What the run says is in the battery. Set before the board moves, read
/// back through the register file.
pub const Battery = struct {
    soc_pct: u8 = cell.default_soc,
    charging: bool = false,
};

pub const Gauge = struct {
    registers: [reg.count]u8 = @splat(0),
    battery: Battery = .{},
    /// Where the pointer stands, whether this transfer named it, and the
    /// high byte of a word that has not landed yet.
    pointer: u8 = 0,
    pointed: bool = false,
    high: ?u8 = null,
    /// Words the monitor read, and words that landed in a writable register.
    reads: u32 = 0,
    writes: u32 = 0,
    /// Stores into a register the gauge measures for itself.
    read_only: u32 = 0,
    /// A pointer landing inside a word rather than on one. dev served from
    /// any byte, so a read at 0x05 answered with half of SOC.
    misaligned: u32 = 0,
    /// A pointer naming a register this part does not have.
    unmapped: u32 = 0,
    /// Power-on-reset commands carried out. dev filed the command away.
    resets: u32 = 0,
    /// Transfers that ended holding half a word, which the gauge never saw.
    /// dev landed the stray byte over half a register.
    torn: u32 = 0,

    /// Lay the register file down from the battery state.
    pub fn init(battery: Battery) Error!Gauge {
        var gauge = Gauge{};
        try gauge.setBattery(battery);
        return gauge;
    }

    /// The part as it comes up when plugged in: a default battery behind a
    /// seeded register file, not the zeroed file `.{}` leaves.
    pub fn powerOn() Gauge {
        return init(.{}) catch unreachable;
    }

    pub fn quiet(self: *const Gauge) bool {
        return self.reads == 0 and self.writes == 0 and self.read_only == 0 and
            self.misaligned == 0 and self.unmapped == 0 and self.resets == 0 and
            self.torn == 0;
    }

    /// A state-of-charge over full is refused rather than quietly clamped,
    /// which is what dev did with it.
    pub fn setBattery(self: *Gauge, battery: Battery) Error!void {
        if (battery.soc_pct > cell.full) return Error.SocOutOfRange;
        self.battery = battery;
        self.seed();
    }

    fn seed(self: *Gauge) void {
        self.registers = @splat(0);
        self.put(reg.vcell, cell.vcell);
        self.put(reg.soc, @as(u16, self.battery.soc_pct) << cell.percent_shift);
        self.put(reg.version, cell.version);
        const rate = if (self.battery.charging) cell.crate_magnitude else -cell.crate_magnitude;
        self.put(reg.crate, @bitCast(rate));
    }

    fn put(self: *Gauge, at: u8, value: u16) void {
        self.registers[at] = @truncate(value >> cell.percent_shift);
        self.registers[at + 1] = @truncate(value);
    }

    pub fn word(self: *const Gauge, at: u8) u16 {
        return (@as(u16, self.registers[at]) << cell.percent_shift) | self.registers[at + 1];
    }

    /// The pointer first, then the word high byte first.
    pub fn write(self: *Gauge, byte: u8) void {
        if (!self.pointed) {
            self.point(byte);
            return;
        }
        const high = self.high orelse {
            self.high = byte;
            return;
        };
        self.high = null;
        self.land((@as(u16, high) << cell.percent_shift) | byte);
    }

    fn point(self: *Gauge, at: u8) void {
        if (at == reg.command) {
            self.pointer = at;
            self.pointed = true;
            return;
        }
        if (at % reg.word_bytes != 0) {
            self.misaligned += 1;
            return;
        }
        if (at >= reg.count) {
            self.unmapped += 1;
            return;
        }
        self.pointer = at;
        self.pointed = true;
    }

    fn land(self: *Gauge, value: u16) void {
        if (self.pointer == reg.command) {
            if (value == power_on_reset) {
                self.seed();
                self.resets += 1;
            }
            return;
        }
        if (owned(self.pointer)) {
            self.read_only += 1;
        } else {
            self.put(self.pointer, value);
            self.writes += 1;
        }
        self.advance();
    }

    fn advance(self: *Gauge) void {
        if (@as(usize, self.pointer) + reg.word_bytes >= reg.count) {
            self.pointed = false;
            return;
        }
        self.pointer += @intCast(reg.word_bytes);
    }

    /// Serve whole words from the pointer on. The command register is
    /// write-only, and a burst that reaches the end of the map stops there.
    pub fn read(self: *Gauge, into: []u8) usize {
        if (self.pointer == reg.command) {
            self.unmapped += 1;
            return 0;
        }
        var served: usize = 0;
        while (served < into.len) : (served += 1) {
            const at = @as(usize, self.pointer) + served;
            if (at >= reg.count) break;
            into[served] = self.registers[at];
        }
        if (served == 0) return 0;
        self.reads += 1;
        self.pointer = @intCast(@min(@as(usize, self.pointer) + served, reg.count - reg.word_bytes));
        return served;
    }

    /// A transfer ended. A word the controller only half wrote is lost with
    /// it, the way it is lost on the wire.
    pub fn stop(self: *Gauge) void {
        if (self.high != null) {
            self.torn += 1;
            self.high = null;
        }
        self.pointed = false;
    }

    pub fn device(self: *Gauge) bus.Device {
        return .{
            .address = address,
            .context = self,
            .writeFn = writeThunk,
            .readFn = readThunk,
            .stopFn = stopThunk,
        };
    }
};

/// Registers the gauge measures for itself: the host only reads these.
fn owned(at: u8) bool {
    return at == reg.vcell or at == reg.soc or at == reg.version or
        at == reg.crate or at == reg.status;
}

fn writeThunk(context: *anyopaque, byte: u8) void {
    const self: *Gauge = @ptrCast(@alignCast(context));
    self.write(byte);
}

fn readThunk(context: *anyopaque, into: []u8) usize {
    const self: *Gauge = @ptrCast(@alignCast(context));
    return self.read(into);
}

fn stopThunk(context: *anyopaque) void {
    const self: *Gauge = @ptrCast(@alignCast(context));
    self.stop();
}
