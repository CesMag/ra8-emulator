const std = @import("std");
const ra8 = @import("ra8");
const format = ra8.chip.core.cpu.fpu.format;
const mul = ra8.chip.core.cpu.fpu.mul;
const Fpscr = ra8.chip.core.cpu.fpu.fpscr.Fpscr;

test "the sign bit is the top bit of each format" {
    try std.testing.expectEqual(@as(u32, 0x8000_0000), mul.signBit(format.single));
    try std.testing.expectEqual(@as(u64, 0x8000_0000_0000_0000), mul.signBit(format.double));
}

test "an exact product raises no flags" {
    var fpscr = Fpscr{};
    try std.testing.expectEqual(@as(u32, 0x4180_0000), mul.mul(format.single, 0x4080_0000, 0x4080_0000, &fpscr));
    try std.testing.expectEqual(Fpscr{}, fpscr);
}

test "a full-width double product rounds once" {
    var fpscr = Fpscr{};
    const third: u64 = 0x3FD5_5555_5555_5555;
    try std.testing.expectEqual(@as(u64, 0x3FBC_71C7_1C71_C71C), mul.mul(format.double, third, third, &fpscr));
    try std.testing.expectEqual(@as(u1, 1), fpscr.ixc);
}

test "nmul flips only the sign of the rounded product" {
    var fpscr = Fpscr{};
    try std.testing.expectEqual(@as(u32, 0xC180_0000), mul.nmul(format.single, 0x4080_0000, 0x4080_0000, &fpscr));
}
