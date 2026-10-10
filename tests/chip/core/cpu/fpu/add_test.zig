const std = @import("std");
const ra8 = @import("ra8");
const add = ra8.chip.core.cpu.fpu.add;
const Real = ra8.chip.core.cpu.fpu.format.Real;

fn r(sign: u1, mant: u128, exp: i32) Real {
    return .{ .sign = sign, .mant = mant, .exp = exp };
}

test "same signs add their aligned mantissas" {
    const s = add.exactSum(r(0, 3, 2), r(0, 1, 0));
    try std.testing.expectEqual(r(0, 13, 0), s);
}

test "opposite signs subtract, and the larger magnitude sets the sign" {
    try std.testing.expectEqual(r(1, 11, 0), add.exactSum(r(0, 1, 0), r(1, 3, 2)));
}

test "equal magnitudes cancel to a zero mantissa, whose sign the caller picks" {
    try std.testing.expectEqual(@as(u128, 0), add.exactSum(r(0, 4, 0), r(1, 1, 2)).mant);
}

test "a zero term leaves the other untouched" {
    try std.testing.expectEqual(r(1, 5, -3), add.exactSum(r(0, 0, 0), r(1, 5, -3)));
}

test "an operand past the alignment limit becomes a one-unit stand-in" {
    const s = add.exactSum(r(0, 1, 0), r(0, 7, -500));
    try std.testing.expectEqual(-add.align_limit, s.exp);
    try std.testing.expectEqual((@as(u128, 1) << @intCast(add.align_limit)) + 1, s.mant);
}
