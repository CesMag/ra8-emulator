//! A debugger's store into the debug units, handed on to the models.
//!
//! gdb writes memory with `M` and `X`, which land in the engine's memory
//! without passing the step hook, so the DWT and DEMCR models never see
//! them. A firmware store reaches them through step_hook.zig's `stored`;
//! this is the same hand-on for the debugger. Without it a comparator or
//! TRCENA set from gdb is in memory but not in the model, and the next
//! unit sync writes the model's stale view back over it.
//!
//! The units are read back through the core the debugger has selected
//! (src/session/core_view.zig), so a Zig session hands its stores on
//! the same way (RA8EMU-483).
const std = @import("std");
const core_view = @import("../../session/core_view.zig");
const stop_machine = @import("../../session/stop_machine.zig");
const dwt = @import("ra8_chip").periph.dwt;
const dcb = @import("ra8_chip").periph.dcb;

/// Hand a debugger store of `length` bytes at `address` to the models.
pub fn forward(core: core_view.View, machine: *stop_machine.Machine, address: u32, length: usize) void {
    const end = @as(u64, address) + length;
    // A debugger store to DWT_CYCCNT is not a count: look again afresh.
    if (overlaps(address, end, dwt.base + dwt.offsets.cyccnt, 4)) machine.dwt.cycles_primed = false;
    if (overlaps(address, end, dcb.demcr_address, 4)) {
        machine.dwt.trcena = read(core, dcb.demcr_address) & dcb.demcr_bits.trcena != 0;
    }
    var offset: u32 = dwt.offsets.comp0;
    while (offset < dwt.limits.end) : (offset += 4) {
        if (overlaps(address, end, dwt.base + offset, 4)) _ = machine.dwt.write(offset, read(core, dwt.base + offset));
    }
    keepNumcomp(core, machine, address, end);
}

/// DWT_CTRL.NUMCOMP is read-only to a debugger too, so a store over
/// DWT_CTRL is put back with this core's comparator count.
fn keepNumcomp(core: core_view.View, machine: *stop_machine.Machine, address: u32, end: u64) void {
    if (!overlaps(address, end, dwt.base, 4)) return;
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &bytes, machine.dwt.ctrlWord(read(core, dwt.base)), .little);
    core.write(dwt.base, &bytes) catch return;
}

fn overlaps(address: u32, end: u64, from: u32, span: u32) bool {
    return address < @as(u64, from) + span and end > from;
}

fn read(core: core_view.View, address: u32) u32 {
    var bytes: [4]u8 = .{ 0, 0, 0, 0 };
    core.read(address, &bytes) catch return 0;
    return std.mem.readInt(u32, &bytes, .little);
}
