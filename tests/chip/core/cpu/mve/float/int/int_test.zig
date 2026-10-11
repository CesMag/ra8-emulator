//! Covers src/chip/core/cpu/mve/float/int/int.zig.
const std = @import("std");
const ra8 = @import("ra8");
const float_int = ra8.chip.core.cpu.mve.float.int;

test "a lane whose first byte is not predicated raises no flags" {
    var fpscr: ra8.chip.core.cpu.fpu.fpscr.Fpscr = .{};
    const nan: u128 = 0x7FC00000;
    try std.testing.expectEqual(@as(u128, 0x0000FFFF), float_int.toInt(0xFFFFFFFF, nan, .word, false, .zero, 0, 0x000C, &fpscr));
    try std.testing.expectEqual(@as(u1, 0), fpscr.ioc);
}

test "an F16 lane converts under FZ16 without IDC" {
    var fpscr: ra8.chip.core.cpu.fpu.fpscr.Fpscr = .{ .fz16 = 1 };
    try std.testing.expectEqual(@as(u128, 0), float_int.toInt(0, 0x0001, .half, false, .zero, 0, 0xFFFF, &fpscr));
    try std.testing.expectEqual(@as(u32, 0), ra8.chip.core.cpu.fpu.case.flagsOf(fpscr));
}
