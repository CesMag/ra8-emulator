//! DebugMonitor pends on the Zig core's debug path (RA8EMU-673).
//!
//! With halting debug off, an FPB or DWT event does not stop the core: the
//! stop machine holds it (Machine.takeMonitor), and it becomes DEMCR.MON_PEND and a DFSR latch for the
//! interrupt controller to take at its next boundary
//! (src/chip/periph/debug_monitor.zig). zig_drive.zig does the same through
//! this, once per instruction, so firmware running a debug monitor sees
//! the same pend on either core. With MON_EN clear the event is dropped.
const std = @import("std");
const zig_core = @import("zig_core.zig");
const stop_machine = @import("stop_machine.zig");
const dcb = @import("ra8_chip").periph.dcb;

/// Pend DebugMonitor for the event the last instruction raised, if any.
pub fn take(core: zig_core.ZigCore, machine: *stop_machine.Machine) void {
    const cause = machine.takeMonitor() orelse return;
    pend(core, machine, cause);
}

/// Set DEMCR.MON_PEND and latch DFSR for `cause` when DEMCR.MON_EN is set.
pub fn pend(core: zig_core.ZigCore, machine: *stop_machine.Machine, cause: stop_machine.Monitor) void {
    const demcr = core.readWord(dcb.demcr_address) catch return;
    if (demcr & dcb.demcr_bits.mon_en == 0) return;
    store(core, dcb.demcr_address, demcr | dcb.demcr_bits.mon_pend);
    machine.dcb.latch(if (cause == .breakpoint) dcb.dfsr_bits.bkpt else dcb.dfsr_bits.dwttrap);
    store(core, dcb.dfsr_address, machine.dcb.dfsr);
}

fn store(core: zig_core.ZigCore, address: u32, word: u32) void {
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &bytes, word, .little);
    core.write(address, &bytes) catch {};
}
