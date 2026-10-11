//! Covers src/chip/core/cpu/mve/int/int.zig.
const std = @import("std");
const ra8 = @import("ra8");
const int = ra8.chip.core.cpu.mve.int;

test "extend reads a lane signed or unsigned" {
    try std.testing.expectEqual(@as(i64, -1), int.extend(0xFF, .byte, false));
    try std.testing.expectEqual(@as(i64, 255), int.extend(0xFF, .byte, true));
    try std.testing.expectEqual(@as(i64, -0x8000_0000), int.extend(0x8000_0000, .word, false));
    try std.testing.expectEqual(@as(i64, 0x7FFF), int.extend(0x7FFF, .half, false));
}

test "bounds per width" {
    try std.testing.expectEqual([2]i64{ -128, 127 }, int.bounds(.byte, false));
    try std.testing.expectEqual([2]i64{ 0, 0xFFFF }, int.bounds(.half, true));
    try std.testing.expectEqual([2]i64{ 0, 0xFFFF_FFFF }, int.bounds(.word, true));
}

test "lanes stay independent: no carry crosses a lane" {
    const all_ones = ~@as(u128, 0);
    try std.testing.expectEqual(@as(u128, 0), int.lanewise(all_ones, 0x0101_0101_0101_0101_0101_0101_0101_0101, .byte, .add));
    try std.testing.expectEqual(@as(u128, 0x0001_0000), int.lanewise(0x0001_0000, 0x0001_0000, .half, .mul));
}

test "a saturating op that clamps nothing reports no saturation" {
    const r = int.saturating(1, 2, .word, false, false);
    try std.testing.expectEqual(@as(u128, 3), r.value);
    try std.testing.expect(!r.saturated);
}

test "pairLane works at full precision before narrowing" {
    try std.testing.expectEqual(@as(i64, 0xFF), int.pairLane(-128, 127, .abd));
    try std.testing.expectEqual(@as(i64, 0xFF), int.pairLane(0xFF, 0xFF, .hadd));
    try std.testing.expectEqual(@as(i64, 2), int.pairLane(1, 2, .rhadd));
    try std.testing.expectEqual(@as(i64, -1), int.pairLane(0, 1, .hsub));
}
