//! Covers src/chip/core/cpu/mve/bitwise/bitwise.zig.
const std = @import("std");
const ra8 = @import("ra8");
const bitwise = ra8.chip.core.cpu.mve.bitwise;

const ones: u128 = ~@as(u128, 0);
const x: u128 = 0xF0F0_F0F0_0000_FFFF_1234_5678_AAAA_5555;

test "each op against all-zero and all-one Qm" {
    try std.testing.expectEqual(@as(u128, 0), bitwise.apply(x, 0, .@"and"));
    try std.testing.expectEqual(x, bitwise.apply(x, ones, .@"and"));
    try std.testing.expectEqual(x, bitwise.apply(x, 0, .bic));
    try std.testing.expectEqual(@as(u128, 0), bitwise.apply(x, ones, .bic));
    try std.testing.expectEqual(x, bitwise.apply(x, 0, .orr));
    try std.testing.expectEqual(ones, bitwise.apply(x, ones, .orr));
    try std.testing.expectEqual(ones, bitwise.apply(x, 0, .orn));
    try std.testing.expectEqual(x, bitwise.apply(x, ones, .orn));
    try std.testing.expectEqual(x, bitwise.apply(x, 0, .eor));
    try std.testing.expectEqual(~x, bitwise.apply(x, ones, .eor));
}

test "VORR with Qn == Qm is a copy" {
    try std.testing.expectEqual(x, bitwise.apply(x, x, .orr));
}
