//! DWT_CYCCNT and the halt record on the Zig core's debug path (RA8EMU-172).
//!
//! DWT_CYCCNT is counted one instruction at a time
//! while a Cycle Counter comparator is live (src/session/cycle_count.zig),
//! and on a halt writes the count back and latches DFSR. The Zig debug path
//! runs no board clock, so this does the same from zig_drive.zig: one count
//! per instruction while the watch is live, the comparator checked on each,
//! and DFSR latched and stored when the machine stops the core.
const std = @import("std");
const zig_core = @import("core.zig");
const stop_machine = @import("../stop_machine.zig");
const cycle_count = @import("../cycle_count.zig");
const dwt = @import("ra8_chip").periph.dwt;
const dcb = @import("ra8_chip").periph.dcb;

const cyccnt_address: u32 = dwt.base + dwt.offsets.cyccnt;

pub const Clock = struct {
    count: cycle_count.Count = .{},

    /// Before the instruction at the PC runs: count it, and arm the
    /// comparator's stop when this is the instruction that reaches it.
    pub fn tick(self: *Clock, core: zig_core.ZigCore, machine: *stop_machine.Machine) void {
        if (!machine.dwt.watchesCycles()) {
            machine.dwt.cycles_primed = false;
            self.count.forget();
            return;
        }
        const stored = core.readWord(cyccnt_address) catch return;
        if (machine.dwt.cycleCounted(self.count.at(stored))) |index| machine.onUnitMatch(index);
    }

    /// The machine stopped the core for `why`: put the count back into
    /// DWT_CYCCNT and record why in DFSR, so a debugger reading either at
    /// the stop sees why it stopped.
    pub fn halted(self: *Clock, core: zig_core.ZigCore, machine: *stop_machine.Machine, why: stop_machine.Stop) void {
        if (self.count.settle()) |count| store(core, cyccnt_address, count);
        machine.dcb.latch(dfsrFor(why));
        store(core, dcb.dfsr_address, machine.dcb.dfsr);
    }
};

/// The DFSR bits a halt records.
pub fn dfsrFor(stop: stop_machine.Stop) u32 {
    return switch (stop) {
        .breakpoint, .unit_break => dcb.dfsr_bits.bkpt,
        .watchpoint, .unit_watch => dcb.dfsr_bits.dwttrap,
        .stepped, .halt_requested => dcb.dfsr_bits.halted,
    };
}

fn store(core: zig_core.ZigCore, address: u32, word: u32) void {
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &bytes, word, .little);
    core.write(address, &bytes) catch {};
}
