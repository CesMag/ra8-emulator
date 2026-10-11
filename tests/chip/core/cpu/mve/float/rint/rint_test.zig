//! Covers src/chip/core/cpu/mve/float_rint.zig.
const std = @import("std");
const ra8 = @import("ra8");
const float_rint = ra8.chip.core.cpu.mve.float.rint;

test "each kind names its rounding" {
    try std.testing.expectEqual(ra8.chip.core.cpu.fpu.rounding.Rounding.ties_away, float_rint.Kind.a.rounding());
    try std.testing.expectEqual(ra8.chip.core.cpu.fpu.rounding.Rounding.nearest, float_rint.Kind.x.rounding());
    try std.testing.expectEqual(ra8.chip.core.cpu.fpu.rounding.Rounding.zero, float_rint.Kind.z.rounding());
}

test "a lane whose first byte is not predicated raises no flags" {
    var fpscr: ra8.chip.core.cpu.fpu.fpscr.Fpscr = .{};
    const half: u128 = 0x3FC00000;
    try std.testing.expectEqual(@as(u128, 0x4000FFFF), float_rint.rint(0xFFFFFFFF, half, .word, .x, 0x000C, &fpscr));
    try std.testing.expectEqual(@as(u1, 0), fpscr.ixc);
}

test "the RMode in FPSCR does not change VRINTX" {
    var fpscr: ra8.chip.core.cpu.fpu.fpscr.Fpscr = .{ .rmode = .zero };
    try std.testing.expectEqual(@as(u128, 0x40000000), float_rint.rint(0, 0x3FC00000, .word, .x, 0xFFFF, &fpscr));
}
