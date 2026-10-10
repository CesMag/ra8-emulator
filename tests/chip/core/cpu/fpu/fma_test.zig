const std = @import("std");
const ra8 = @import("ra8");
const fma = ra8.chip.core.cpu.fpu.fma;
const format = ra8.chip.core.cpu.fpu.format;
const nan = ra8.chip.core.cpu.fpu.nan;
const Fpscr = ra8.chip.core.cpu.fpu.fpscr.Fpscr;

fn w(sign: u1, mant: u256, exp: i32) fma.Wide {
    return .{ .sign = sign, .mant = mant, .exp = exp };
}

test "top is one past the weight of the highest set bit" {
    try std.testing.expectEqual(@as(i32, 3), fma.top(w(0, 0b101, 0)));
    try std.testing.expectEqual(@as(i32, -7), fma.top(w(0, 1, -8)));
}

test "close terms add exactly" {
    try std.testing.expectEqual(w(0, 13, 0), fma.exactSum(w(0, 3, 2), w(0, 1, 0)));
    try std.testing.expectEqual(w(1, 11, 0), fma.exactSum(w(0, 1, 0), w(1, 3, 2)));
}

test "a term far below the other's last bit becomes a stand-in two below the cut" {
    // big has 53 bits from 2^0, so the cut is min(0, 53 - 57) = -4.
    const big = w(0, 1 << 52, 0);
    const s = fma.exactSum(big, w(0, 12345, -900));
    try std.testing.expectEqual(@as(i32, -6), s.exp);
    try std.testing.expectEqual((@as(u256, 1) << 58) + 1, s.mant);
}

test "a wide product keeps its low bits against a nearby addend" {
    const product = w(0, (@as(u256, 1) << 105) + 1, -105);
    const s = fma.exactSum(product, w(1, 1, 0));
    try std.testing.expectEqual(w(0, 1, -105), s);
}

test "narrow keeps short values and folds long ones into a sticky bit" {
    try std.testing.expectEqual(format.Real{ .sign = 1, .mant = 5, .exp = 3 }, fma.narrow(w(1, 5, 3)));
    const r = fma.narrow(w(0, (@as(u256, 1) << 200) | 1, 0));
    try std.testing.expectEqual(@as(i32, 81), r.exp);
    try std.testing.expectEqual((@as(u128, 1) << 119) | 1, r.mant);
}

test "three-operand NaN priority: any sNaN, then the earliest qNaN" {
    var fpscr = Fpscr{};
    const got = nan.processNaNs3(format.single, .{ .qnan, .nonzero, .snan }, .{ 0x7FC0_0001, 0x3F80_0000, 0x7F80_0003 }, &fpscr);
    try std.testing.expectEqual(@as(?u32, 0x7FC0_0003), got);
    try std.testing.expectEqual(@as(u1, 1), fpscr.ioc);
    try std.testing.expectEqual(@as(?u32, null), nan.processNaNs3(format.single, .{ .zero, .nonzero, .zero }, .{ 0, 1, 0 }, &fpscr));
}
