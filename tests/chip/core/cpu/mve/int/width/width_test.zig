//! Covers src/chip/core/cpu/mve/int_width.zig.
const std = @import("std");
const ra8 = @import("ra8");
const width = ra8.chip.core.cpu.mve.int.width;

test "wider doubles the lane size" {
    try std.testing.expectEqual(ra8.chip.core.cpu.mve.qreg.Size.half, width.wider(.byte));
    try std.testing.expectEqual(ra8.chip.core.cpu.mve.qreg.Size.word, width.wider(.half));
}

test "narrow keeps the half of Qd it does not write" {
    const r = width.narrow(0xAAAA_AAAA_AAAA_AAAA, 0x0000_0012_0000_0034, .half, .bottom, .{});
    try std.testing.expectEqual(@as(u128, 0xAAAA_0012_AAAA_0034), r.value & 0xFFFF_FFFF_FFFF_FFFF);
    try std.testing.expect(!r.saturated);
}

test "widen sign-extends into a lane twice as wide unless unsigned" {
    try std.testing.expectEqual(@as(u128, 0xFF80), width.widen(0x80, .byte, .bottom, false, 0) & 0xFFFF);
    try std.testing.expectEqual(@as(u128, 0x0080), width.widen(0x80, .byte, .bottom, true, 0) & 0xFFFF);
}
