//! Tests for src/chip/periph/exc_return.zig.
const std = @import("std");
const ra8 = @import("ra8");
const mod = ra8.chip.periph.exc_return;

test "an address in the EXC_RETURN range is a return, and ordinary code is not" {
    try std.testing.expect(mod.is(mod.to.thread_main));
    try std.testing.expect(mod.is(mod.to.thread_process));
    try std.testing.expect(mod.is(mod.to.handler_main));
    try std.testing.expect(mod.is(0xFFFF_FF00));
    try std.testing.expect(!mod.is(0xFFFF_FEFF));
    try std.testing.expect(!mod.is(0x0200_022C));
}

test "MODE picks thread mode and SPSEL picks the process stack" {
    try std.testing.expect(mod.toThread(mod.to.thread_main));
    try std.testing.expect(mod.toThread(mod.to.thread_process));
    try std.testing.expect(!mod.toThread(mod.to.handler_main));

    try std.testing.expect(!mod.usesProcessStack(mod.to.thread_main));
    try std.testing.expect(mod.usesProcessStack(mod.to.thread_process));
}

test "a return into a handler is on the main stack whatever SPSEL says" {
    // 0xFFFF_FFF5 has SPSEL set and MODE clear. Handler mode has no process
    // stack to go back to, so the bit is meaningless there and is ignored.
    const into_handler_with_spsel: u32 = mod.to.handler_main | mod.field.spsel;
    try std.testing.expect(!mod.toThread(into_handler_with_spsel));
    try std.testing.expect(!mod.usesProcessStack(into_handler_with_spsel));
}

test "entry hands back the value that matches where it came from" {
    try std.testing.expectEqual(mod.to.thread_main, mod.forEntry(false, false));
    try std.testing.expectEqual(mod.to.thread_process, mod.forEntry(false, true));
    // Preempting a handler goes back to that handler, never to a thread
    // stack, even when the thread underneath was on one.
    try std.testing.expectEqual(mod.to.handler_main, mod.forEntry(true, false));
    try std.testing.expectEqual(mod.to.handler_main, mod.forEntry(true, true));
}

test "CONTROL.SPSEL is bit 1, and FPCA above it is left alone" {
    try std.testing.expectEqual(@as(u32, 1 << 1), mod.control.spsel);
    try std.testing.expectEqual(@as(u32, 1 << 0), mod.control.npriv);
    try std.testing.expectEqual(@as(u32, 1 << 2), mod.control.fpca);
    try std.testing.expectEqual(@as(u32, 0), mod.control.spsel & mod.control.fpca);
}
