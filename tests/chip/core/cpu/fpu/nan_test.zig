const std = @import("std");
const ra8 = @import("ra8");
const format = ra8.chip.core.cpu.fpu.format;
const nan = ra8.chip.core.cpu.fpu.nan;
const Fpscr = ra8.chip.core.cpu.fpu.fpscr.Fpscr;

test "the default NaN is 0x7FC00000 and 0x7FF8000000000000" {
    try std.testing.expectEqual(@as(u32, 0x7FC0_0000), nan.defaultNaN(format.single));
    try std.testing.expectEqual(@as(u64, 0x7FF8_0000_0000_0000), nan.defaultNaN(format.double));
}

test "a quiet NaN passes through untouched and raises nothing" {
    var fpscr = Fpscr{};
    try std.testing.expectEqual(@as(u32, 0xFFC0_1234), nan.processNaN(format.single, .qnan, 0xFFC0_1234, &fpscr));
    try std.testing.expectEqual(Fpscr{}, fpscr);
}

test "a signalling NaN is quietened, keeps sign and payload, and sets IOC" {
    var fpscr = Fpscr{};
    try std.testing.expectEqual(@as(u32, 0xFFC0_0005), nan.processNaN(format.single, .snan, 0xFF80_0005, &fpscr));
    try std.testing.expectEqual(@as(u1, 1), fpscr.ioc);
}

test "DN replaces the result but a signalling NaN still sets IOC" {
    var fpscr = Fpscr{ .dn = 1 };
    try std.testing.expectEqual(@as(u32, 0x7FC0_0000), nan.processNaN(format.single, .snan, 0xFF80_0005, &fpscr));
    try std.testing.expectEqual(@as(u1, 1), fpscr.ioc);
}

test "two operands: signalling beats quiet, then the first beats the second" {
    var fpscr = Fpscr{};
    try std.testing.expectEqual(@as(?u32, 0x7FC0_0002), nan.processNaNs(format.single, .qnan, .snan, 0x7FC0_0001, 0x7F80_0002, &fpscr));
    try std.testing.expectEqual(@as(?u32, 0x7FC0_0001), nan.processNaNs(format.single, .qnan, .qnan, 0x7FC0_0001, 0x7FC0_0002, &fpscr));
    try std.testing.expectEqual(@as(?u32, null), nan.processNaNs(format.single, .nonzero, .zero, 0x3F80_0000, 0, &fpscr));
}
