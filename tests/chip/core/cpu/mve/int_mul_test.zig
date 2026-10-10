//! Covers src/chip/core/cpu/mve/int_mul.zig.
const std = @import("std");
const ra8 = @import("ra8");
const mul = ra8.chip.core.cpu.mve.int_mul;

test "VQDMULH saturates only the most negative value squared" {
    const min = mul.multiplyHigh(0x8000, 0x8000, .half, .{ .double = true });
    try std.testing.expectEqual(@as(u128, 0x7FFF), min.value & 0xFFFF);
    try std.testing.expect(min.saturated);
    const near = mul.multiplyHigh(0x8000, 0x8001, .half, .{ .double = true });
    try std.testing.expectEqual(@as(u128, 0x7FFF), near.value & 0xFFFF);
    try std.testing.expect(!near.saturated);
}

test "VMULH keeps the top half, VRMULH rounds it" {
    try std.testing.expectEqual(@as(u128, 0), mul.multiplyHigh(0x80, 0x01, .byte, .{ .unsigned = true }).value & 0xFF);
    try std.testing.expectEqual(@as(u128, 1), mul.multiplyHigh(0x80, 0x01, .byte, .{ .unsigned = true, .round = true }).value & 0xFF);
}

test "VMLA and VMLAS wrap to the lane" {
    try std.testing.expectEqual(@as(u128, 0x00), mul.multiplyAddScalar(0x01, 0xFF, 1, .byte, .vmla) & 0xFF);
    try std.testing.expectEqual(@as(u128, 0x07), mul.multiplyAddScalar(0x02, 0x03, 1, .byte, .vmlas) & 0xFF);
}
