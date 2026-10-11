//! Covers src/chip/core/cpu/mve/compare/compare.zig.
const std = @import("std");
const ra8 = @import("ra8");
const compare = ra8.chip.core.cpu.mve.compare;

test "condOf numbers the conditions as the encoding does" {
    try std.testing.expectEqual(compare.Cond.eq, compare.condOf(false, false, false));
    try std.testing.expectEqual(compare.Cond.ne, compare.condOf(false, false, true));
    try std.testing.expectEqual(compare.Cond.hi, compare.condOf(false, true, true));
    try std.testing.expectEqual(compare.Cond.lt, compare.condOf(true, false, true));
    try std.testing.expectEqual(compare.Cond.le, compare.condOf(true, true, true));
}

test "holds reads unsigned for CS and HI and signed for GT" {
    try std.testing.expect(compare.holds(0x80, 0x7F, .byte, .hi));
    try std.testing.expect(!compare.holds(0x80, 0x7F, .byte, .gt));
    try std.testing.expect(compare.holds(0xFFFF, 0xFFFF, .half, .cs));
}

test "a true element sets every byte it spans" {
    try std.testing.expectEqual(@as(u16, 0xFFFF), compare.compare(0, 0, .word, .eq));
    try std.testing.expectEqual(@as(u16, 0x000F), compare.compare(1, 0, .word, .hi) & 0x000F);
}
