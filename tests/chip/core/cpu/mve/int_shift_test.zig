//! Covers src/chip/core/cpu/mve/int_shift.zig.
const std = @import("std");
const ra8 = @import("ra8");
const shift = ra8.chip.core.cpu.mve.int_shift;

test "shiftLane shifts left, right and rounds" {
    try std.testing.expectEqual(@as(i128, 8), shift.shiftLane(1, 3, false));
    try std.testing.expectEqual(@as(i128, -1), shift.shiftLane(-3, -2, false));
    try std.testing.expectEqual(@as(i128, -1), shift.shiftLane(-3, -2, true));
    try std.testing.expectEqual(@as(i128, 2), shift.shiftLane(3, -1, true));
}

test "shiftLane clamps huge amounts without changing the answer" {
    try std.testing.expectEqual(@as(i128, 1) << 33, shift.shiftLane(1, 127, false));
    try std.testing.expectEqual(@as(i128, -1), shift.shiftLane(-5, -128, false));
    try std.testing.expectEqual(@as(i128, 0), shift.shiftLane(-5, -128, true));
}

test "splat puts the shift in the bottom byte of every lane" {
    try std.testing.expectEqual(@as(u128, 0x00FD_00FD_00FD_00FD_00FD_00FD_00FD_00FD), shift.splat(-3, .half));
    try std.testing.expectEqual(@as(u128, 0x0404_0404_0404_0404_0404_0404_0404_0404), shift.splat(4, .byte));
}

test "a register shift of zero leaves the vector alone" {
    const r = shift.byRegister(0x1234_5678, 0, .word, .{ .saturate = true });
    try std.testing.expectEqual(@as(u128, 0x1234_5678), r.value);
    try std.testing.expect(!r.saturated);
}
