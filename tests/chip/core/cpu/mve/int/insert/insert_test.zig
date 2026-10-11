//! Covers src/chip/core/cpu/mve/int_insert.zig.
const std = @import("std");
const ra8 = @import("ra8");
const insert = ra8.chip.core.cpu.mve.int_insert;

test "VSRI keeps the top n bits of each Qd lane" {
    try std.testing.expectEqual(@as(u128, 0xF0F0_F0F0), insert.sri(0xFFFF_FFFF, 0x0000_0000, .byte, 4) & 0xFFFF_FFFF);
    try std.testing.expectEqual(@as(u128, 0x0FFF_FFFF), insert.sri(0x0000_0000, 0xFFFF_FFFF, .word, 4) & 0xFFFF_FFFF);
}

test "VSLI keeps the bottom n bits of each Qd lane" {
    try std.testing.expectEqual(@as(u128, 0x0F0F_0F0F), insert.sli(0xFFFF_FFFF, 0x0000_0000, .byte, 4) & 0xFFFF_FFFF);
    try std.testing.expectEqual(@as(u128, 0xFFF0), insert.sli(0, 0xFFFF, .half, 4) & 0xFFFF);
}
