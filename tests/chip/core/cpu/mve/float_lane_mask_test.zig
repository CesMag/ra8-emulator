//! Covers float.laneMask in src/chip/core/cpu/mve/float/float.zig.
const std = @import("std");
const ra8 = @import("ra8");
const float = ra8.chip.core.cpu.mve.float;

test "laneMask shifts a lane's byte bits down" {
    try std.testing.expectEqual(@as(u16, 0b1110), float.laneMask(0x00E0, .word, 1));
    try std.testing.expectEqual(@as(u16, 0b10), float.laneMask(0x0020, .half, 2));
    try std.testing.expectEqual(@as(u16, 0), float.laneMask(0x00FF, .word, 2));
}

test "VADD computes a lane predicated past its first byte, without flags" {
    var fpscr: ra8.chip.core.cpu.fpu.fpscr.Fpscr = .{};
    const snan: u128 = 0x7F800001;
    try std.testing.expectEqual(@as(u128, 0x7FC00011), float.binary(0x11111111, snan, 0, .word, .add, 0x000E, &fpscr));
    try std.testing.expectEqual(@as(u1, 0), fpscr.ioc);
}
