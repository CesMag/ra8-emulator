const std = @import("std");
const ra8 = @import("ra8");
const div = ra8.chip.core.cpu.fpu.div;
const format = ra8.chip.core.cpu.fpu.format;
const Real = format.Real;
const Fpscr = ra8.chip.core.cpu.fpu.fpscr.Fpscr;

test "an exact quotient has no sticky bit" {
    const q = div.quotient(.{ .sign = 0, .mant = 6, .exp = 0 }, .{ .sign = 1, .mant = 3, .exp = 0 });
    try std.testing.expectEqual(@as(u1, 1), q.sign);
    // 6 has 3 bits, so it shifts by 127 - 3 = 124 and 6 / 3 leaves 2 << 124.
    try std.testing.expectEqual(@as(u128, 1) << 125, q.mant);
    try std.testing.expectEqual(@as(i32, -124), q.exp);
}

test "a remainder sets the lowest quotient bit" {
    const q = div.quotient(.{ .sign = 0, .mant = 1, .exp = 0 }, .{ .sign = 0, .mant = 3, .exp = 0 });
    try std.testing.expectEqual(@as(u128, 1), q.mant & 1);
    try std.testing.expect(q.mant >> 120 != 0);
}

test "a full-width dividend over a one-bit divisor still fits" {
    const q = div.quotient(.{ .sign = 0, .mant = (1 << 53) - 1, .exp = 0 }, .{ .sign = 0, .mant = 1, .exp = 0 });
    try std.testing.expectEqual(@as(u8, 127), 128 - @as(u8, @clz(q.mant)));
}

test "infinity over zero is infinity without DZC" {
    var fpscr = Fpscr{};
    try std.testing.expectEqual(@as(u32, 0xFF80_0000), div.div(format.single, 0x7F80_0000, 0x8000_0000, &fpscr));
    try std.testing.expectEqual(Fpscr{}, fpscr);
}
