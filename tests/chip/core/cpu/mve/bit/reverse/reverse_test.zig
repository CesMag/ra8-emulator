//! Covers src/chip/core/cpu/mve/bit_reverse.zig.
const std = @import("std");
const ra8 = @import("ra8");
const br = ra8.chip.core.cpu.mve.bit.reverse;

test "a full-width reversal of one element" {
    try std.testing.expectEqual(@as(u32, 0x80), br.element(0x01, 8, 8));
    try std.testing.expectEqual(@as(u32, 0x8000_0000), br.element(0x1, 32, 32));
}

test "keeping fewer bits shifts the reversal right" {
    try std.testing.expectEqual(@as(u32, 0b011), br.element(0b0000_0110, 8, 3));
}

test "zero bits kept clears the lane, a count past the width keeps all" {
    try std.testing.expectEqual(@as(u32, 0), br.element(0xFFFF, 16, 0));
    try std.testing.expectEqual(@as(u32, 0x8000), br.element(0x1, 16, 255));
}

test "only Rm's bottom byte counts" {
    try std.testing.expectEqual(@as(u128, 0), br.reverseShift(0xFF, 0x100, .byte));
}
