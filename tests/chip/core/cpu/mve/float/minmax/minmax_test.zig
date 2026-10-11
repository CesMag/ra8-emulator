//! Covers src/chip/core/cpu/mve/float/minmax/minmax.zig.
const std = @import("std");
const ra8 = @import("ra8");
const float_minmax = ra8.chip.core.cpu.mve.float.minmax;

test "a lane whose first byte is not predicated raises no flags" {
    var fpscr: ra8.chip.core.cpu.fpu.fpscr.Fpscr = .{};
    const snan: u128 = 0x7F800001;
    try std.testing.expectEqual(@as(u128, 0x7FC0FFFF), float_minmax.lanes(0xFFFFFFFF, snan, 0x3F800000, .word, .max, false, 0x000C, &fpscr));
    try std.testing.expectEqual(@as(u1, 0), fpscr.ioc);
}

test "a reduction with no predicated lanes returns the scalar untouched" {
    var fpscr: ra8.chip.core.cpu.fpu.fpscr.Fpscr = .{};
    try std.testing.expectEqual(@as(u32, 0x7F800001), float_minmax.reduce(0x7F800001, 0, .word, .max, false, 0x0000, &fpscr));
    try std.testing.expectEqual(@as(u1, 0), fpscr.ioc);
}
