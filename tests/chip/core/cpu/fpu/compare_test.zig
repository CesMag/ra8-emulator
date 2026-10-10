const std = @import("std");
const ra8 = @import("ra8");
const fpu = ra8.chip.core.cpu.fpu;
const compare = fpu.compare;

test "the NZCV encodings match FPCompare" {
    try std.testing.expectEqual(@as(u4, 0b0011), compare.nzcv.unordered);
    try std.testing.expectEqual(@as(u4, 0b0110), compare.nzcv.equal);
    try std.testing.expectEqual(@as(u4, 0b1000), compare.nzcv.less);
    try std.testing.expectEqual(@as(u4, 0b0010), compare.nzcv.greater);
}

test "the order key is zero for either signed zero" {
    var fpscr: fpu.fpscr.Fpscr = .{};
    const neg = fpu.unpack.unpack(fpu.format.single, 0x8000_0000, &fpscr);
    try std.testing.expectEqual(@as(i128, 0), compare.key(fpu.format.single, neg, 0x8000_0000));
}

test "the order key negates a negative magnitude" {
    var fpscr: fpu.fpscr.Fpscr = .{};
    const u = fpu.unpack.unpack(fpu.format.single, 0xBF80_0000, &fpscr);
    try std.testing.expectEqual(-@as(i128, 0x3F80_0000), compare.key(fpu.format.single, u, 0xBF80_0000));
}
