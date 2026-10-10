//! Covers src/chip/core/cpu/mve/reduce.zig.
const std = @import("std");
const ra8 = @import("ra8");
const reduce = ra8.chip.core.cpu.mve.reduce;

test "VADDV of zero lanes returns the accumulator" {
    try std.testing.expectEqual(@as(u32, 42), reduce.addv(42, 0, .byte, false));
}

test "VADDV reads lanes signed unless unsigned" {
    const all_ones = ~@as(u128, 0);
    try std.testing.expectEqual(@as(u32, 0xFFFF_FFF0), reduce.addv(0, all_ones, .byte, false));
    try std.testing.expectEqual(@as(u32, 16 * 0xFF), reduce.addv(0, all_ones, .byte, true));
}

test "the exchanging dual multiply pairs lane e with lane e^1" {
    try std.testing.expectEqual(@as(u32, 2), reduce.mladav(0, 0x1, 0x2_0000, .half, .{ .exchange = true }));
    try std.testing.expectEqual(@as(u32, 0), reduce.mladav(0, 0x1, 0x2_0000, .half, .{}));
}

test "VMLALDAV keeps the full 64-bit sum" {
    const r = reduce.mlaldav(0, 0x7FFF_FFFF, 0x7FFF_FFFF, .word, .{});
    try std.testing.expectEqual(@as(u64, 0x3FFF_FFFF_0000_0001), r);
}
