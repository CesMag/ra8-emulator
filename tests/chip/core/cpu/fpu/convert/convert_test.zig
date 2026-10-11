const std = @import("std");
const ra8 = @import("ra8");
const fpu = ra8.chip.core.cpu.fpu;
const convert = fpu.convert;
const single = fpu.format.single;
const double = fpu.format.double;

test "a widened NaN keeps its payload at the top of the fraction" {
    try std.testing.expectEqual(@as(u64, 0x7FFF_FFFF_E000_0000), convert.convertNaN(single, double, 0x7FFF_FFFF));
}

test "a narrowed NaN keeps the top of its payload" {
    try std.testing.expectEqual(@as(u32, 0xFFFF_FFFF), convert.convertNaN(double, single, 0xFFFF_FFFF_FFFF_FFFF));
}

test "a NaN converted to its own format is only quietened" {
    try std.testing.expectEqual(@as(u32, 0x7FC0_0001), convert.convertNaN(single, single, 0x7F80_0001));
}
