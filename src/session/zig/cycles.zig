//! Project slot progress for DWT cycle comparators without guest stop writes.
const zig_core = @import("core.zig");
const stop_machine = @import("../stop_machine.zig");
const cycle_count = @import("../cycle_count.zig");
const dwt = @import("ra8_chip").periph.dwt;
const dcb = @import("ra8_chip").periph.dcb;

const cyccnt_address: u32 = dwt.base + dwt.offsets.cyccnt;

pub const Clock = struct {
    count: cycle_count.Count = .{},
    slots: u64 = 0,

    /// Sample progress since the previous gap. Repeated calls at one gap,
    /// including resumes and budget returns, do not advance the counter.
    pub fn tick(self: *Clock, core: zig_core.ZigCore, machine: *stop_machine.Machine) void {
        const delta = core.cpu.slots -| self.slots;
        self.slots = core.cpu.slots;
        const control = core.readWord(dwt.base) catch 0;
        if (!machine.dwt.watchesCycles() or control & 1 == 0) {
            machine.dwt.cycles_primed = false;
            self.count.forget();
            return;
        }
        const stored = core.readWord(cyccnt_address) catch return;
        if (!self.count.known or self.count.base != stored) {
            self.count = .{ .base = stored, .known = true };
        } else self.count.ran +%= @truncate(delta);
        if (machine.dwt.cycleCounted(self.count.base +% self.count.ran)) |index| machine.onUnitMatch(index);
    }

    /// A debugger stop changes only debugger bookkeeping. Guest cycle and
    /// status words are advanced by the board or firmware-visible events.
    pub fn halted(self: *Clock, core: zig_core.ZigCore, machine: *stop_machine.Machine, why: stop_machine.Stop) void {
        _ = self;
        _ = core;
        if (why == .unit_break or why == .unit_watch) machine.dcb.latch(dfsrFor(why));
    }
};

/// The DFSR bits a halt records.
pub fn dfsrFor(stop: stop_machine.Stop) u32 {
    return switch (stop) {
        .breakpoint, .unit_break => dcb.dfsr_bits.bkpt,
        .watchpoint, .unit_watch => dcb.dfsr_bits.dwttrap,
        .stepped, .halt_requested, .history_start, .replay_failed => dcb.dfsr_bits.halted,
    };
}
