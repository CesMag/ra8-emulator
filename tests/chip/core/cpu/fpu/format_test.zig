const std = @import("std");
const ra8 = @import("ra8");
const format = ra8.chip.core.cpu.fpu.format;
const single = format.single;
const double = format.double;

test "single precision is a u32 with bias 127 and smallest normal exponent -126" {
    try std.testing.expectEqual(u32, single.Bits());
    try std.testing.expectEqual(@as(i32, 127), single.bias());
    try std.testing.expectEqual(@as(i32, -126), single.minExp());
}

test "double precision is a u64 with bias 1023 and smallest normal exponent -1022" {
    try std.testing.expectEqual(u64, double.Bits());
    try std.testing.expectEqual(@as(i32, 1023), double.bias());
    try std.testing.expectEqual(@as(i32, -1022), double.minExp());
}

test "the special values pack to their known bit patterns" {
    try std.testing.expectEqual(@as(u32, 0x8000_0000), single.zero(1));
    try std.testing.expectEqual(@as(u32, 0x7F80_0000), single.infinity(0));
    try std.testing.expectEqual(@as(u32, 0xFF7F_FFFF), single.maxNormal(1));
    try std.testing.expectEqual(@as(u64, 0x7FF0_0000_0000_0000), double.infinity(0));
    try std.testing.expectEqual(@as(u64, 0x7FEF_FFFF_FFFF_FFFF), double.maxNormal(0));
}

test "pack keeps only the fraction's own bits" {
    try std.testing.expectEqual(@as(u32, 0x3F80_0000), single.pack(0, 127, 0x0080_0000));
}
