const std = @import("std");
const ra8 = @import("ra8");
const fpu = ra8.chip.core.cpu.fpu;
const single = fpu.format.single;

test "a cumulative IXC survives a 16-bit saturation" {
    var fpscr: fpu.fpscr.Fpscr = .{ .ixc = 1 };
    _ = fpu.fixed.toFixed(single, 0x4348_0001, 16, 8, false, &fpscr);
    try std.testing.expectEqual(@as(u1, 1), fpscr.ixc);
    try std.testing.expectEqual(@as(u1, 1), fpscr.ioc);
}

test "width 32 matches the plain FPToFixed" {
    var a: fpu.fpscr.Fpscr = .{};
    var b: fpu.fpscr.Fpscr = .{};
    const want = fpu.to_int.toFixedBy(single, 0x3FA0_0000, 3, false, .zero, &a);
    try std.testing.expectEqual(want, fpu.fixed.toFixed(single, 0x3FA0_0000, 32, 3, false, &b));
    try std.testing.expectEqual(@as(u32, @bitCast(a)), @as(u32, @bitCast(b)));
}

test "an unsigned 16-bit operand is not sign-extended" {
    var fpscr: fpu.fpscr.Fpscr = .{};
    try std.testing.expectEqual(@as(u32, 0x477F_FF00), fpu.fixed.fromFixed(single, 0xFFFF, 16, 0, true, .nearest, &fpscr));
}
