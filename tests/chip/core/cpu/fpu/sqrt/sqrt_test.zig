const std = @import("std");
const ra8 = @import("ra8");
const sqrt = ra8.chip.core.cpu.fpu.sqrt;
const Real = ra8.chip.core.cpu.fpu.format.Real;

test "an even exponent and a perfect square give an exact root" {
    const r = sqrt.root(.{ .sign = 0, .mant = 9, .exp = 4 });
    try std.testing.expectEqual(@as(u128, 0), r.mant & 1);
    const top: u8 = 128 - @as(u8, @clz(r.mant));
    const want = @as(u128, 3) << @intCast(top - 2);
    try std.testing.expectEqual(want, r.mant);
}

test "an odd exponent folds one bit into the mantissa" {
    const r = sqrt.root(.{ .sign = 0, .mant = 2, .exp = 3 });
    try std.testing.expectEqual(@as(u128, 0), r.mant & 1);
    try std.testing.expectEqual(@as(u128, 1), r.mant >> @intCast(127 - @as(u8, @clz(r.mant))));
}

test "an irrational root keeps a sticky bit and at least 62 bits" {
    const r = sqrt.root(.{ .sign = 0, .mant = 2, .exp = 0 });
    try std.testing.expectEqual(@as(u128, 1), r.mant & 1);
    try std.testing.expect(128 - @as(u8, @clz(r.mant)) >= 62);
}
