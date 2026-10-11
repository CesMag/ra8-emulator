//! Covers src/chip/core/cpu/mve/reduce_minmax.zig.
const std = @import("std");
const ra8 = @import("ra8");
const rm = ra8.chip.core.cpu.mve.reduce.minmax;

const a: u128 = 0x80000000_7FFFFFFF_00FF7F80_FFFF0001;

test "a starting value below every element survives a max of nothing" {
    try std.testing.expectEqual(@as(u32, 0xFFFF_FFF0), rm.maxminv(0xF0, a, .byte, 0, .{ .kind = .max }));
}

test "unsigned max ignores Rda bits above the element width" {
    try std.testing.expectEqual(@as(u32, 0xFFFF), rm.maxminv(0x1234_0000, a, .half, 0xFFFF, .{ .kind = .max, .unsigned = true }));
}

test "the absolute value of the most negative word is 2^31, unsigned" {
    try std.testing.expectEqual(@as(u32, 0x8000_0000), rm.maxminv(0, a, .word, 0xF000, .{ .kind = .max, .abs = true }));
}

test "signed min of halves sign-extends the result" {
    try std.testing.expectEqual(@as(u32, 0xFFFF_8000), rm.maxminv(0, a, .half, 0xFFFF, .{ .kind = .min }));
}
