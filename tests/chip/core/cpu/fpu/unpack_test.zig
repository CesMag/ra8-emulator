const std = @import("std");
const ra8 = @import("ra8");
const format = ra8.chip.core.cpu.fpu.format;
const unpack = ra8.chip.core.cpu.fpu.unpack;
const Fpscr = ra8.chip.core.cpu.fpu.fpscr.Fpscr;

fn kindOf(bits: u32) unpack.Kind {
    var fpscr = Fpscr{};
    return unpack.unpack(format.single, bits, &fpscr).kind;
}

test "zeros, infinities and the two kinds of NaN are told apart" {
    try std.testing.expectEqual(unpack.Kind.zero, kindOf(0x0000_0000));
    try std.testing.expectEqual(unpack.Kind.zero, kindOf(0x8000_0000));
    try std.testing.expectEqual(unpack.Kind.infinity, kindOf(0xFF80_0000));
    try std.testing.expectEqual(unpack.Kind.qnan, kindOf(0x7FC0_0000));
    try std.testing.expectEqual(unpack.Kind.snan, kindOf(0x7F80_0001));
    try std.testing.expectEqual(unpack.Kind.nonzero, kindOf(0x3F80_0000));
}

test "1.0 is 2^23 * 2^-23 with the implicit bit restored" {
    var fpscr = Fpscr{};
    const u = unpack.unpack(format.single, 0x3F80_0000, &fpscr);
    try std.testing.expectEqual(@as(u128, 1 << 23), u.real.mant);
    try std.testing.expectEqual(@as(i32, -23), u.real.exp);
}

test "the smallest denormal is 1 * 2^-149, and FPSCR is left alone" {
    var fpscr = Fpscr{};
    const u = unpack.unpack(format.single, 0x8000_0001, &fpscr);
    try std.testing.expectEqual(unpack.Kind.nonzero, u.kind);
    try std.testing.expectEqual(@as(u1, 1), u.real.sign);
    try std.testing.expectEqual(@as(u128, 1), u.real.mant);
    try std.testing.expectEqual(@as(i32, -149), u.real.exp);
    try std.testing.expectEqual(Fpscr{}, fpscr);
}

test "with FZ set a denormal input is a signed zero and sets IDC" {
    var fpscr = Fpscr{ .fz = 1 };
    const u = unpack.unpack(format.single, 0x8000_0001, &fpscr);
    try std.testing.expectEqual(unpack.Kind.zero, u.kind);
    try std.testing.expectEqual(@as(u1, 1), u.sign);
    try std.testing.expectEqual(@as(u1, 1), fpscr.idc);
}

test "FZ does not touch a true zero, so IDC stays clear" {
    var fpscr = Fpscr{ .fz = 1 };
    _ = unpack.unpack(format.single, 0x0000_0000, &fpscr);
    try std.testing.expectEqual(@as(u1, 0), fpscr.idc);
}

test "double precision unpacks 1.0 as 2^52 * 2^-52" {
    var fpscr = Fpscr{};
    const u = unpack.unpack(format.double, 0x3FF0_0000_0000_0000, &fpscr);
    try std.testing.expectEqual(@as(u128, 1 << 52), u.real.mant);
    try std.testing.expectEqual(@as(i32, -52), u.real.exp);
}
