//! Covers src/chip/core/cpu/mve/predicate.zig.
const std = @import("std");
const ra8 = @import("ra8");
const predicate = ra8.chip.core.cpu.mve.predicate;

test "VPR fields sit where the Arm ARM puts them" {
    const vpr: predicate.Vpr = @bitCast(@as(u32, 0x0042_F00F));
    try std.testing.expectEqual(@as(u16, 0xF00F), vpr.p0);
    try std.testing.expectEqual(@as(u4, 0x2), vpr.mask01);
    try std.testing.expectEqual(@as(u4, 0x4), vpr.mask23);
}

test "expand widens each bit to a byte" {
    try std.testing.expectEqual(@as(u128, 0xFF00_00FF), predicate.expand(0b1001));
    try std.testing.expectEqual(~@as(u128, 0), predicate.expand(0xFFFF));
}

test "merge keeps the old bytes where the mask is clear" {
    const old: u128 = 0x1111_1111_1111_1111_1111_1111_1111_1111;
    const new: u128 = 0x2222_2222_2222_2222_2222_2222_2222_2222;
    const out = predicate.merge(old, new, 0x00F0);
    try std.testing.expectEqual(@as(u128, 0x1111_1111_1111_1111_2222_2222_1111_1111), out);
}

test "an element is active by its lowest byte's bit" {
    try std.testing.expect(predicate.active(0x0010, .word, 1));
    try std.testing.expect(!predicate.active(0x0020, .word, 1));
    try std.testing.expect(predicate.active(0x4000, .half, 7));
    try std.testing.expect(predicate.active(0x8000, .byte, 15));
}

test "beat masks are four bytes each" {
    try std.testing.expectEqual(@as(u4, 0xA), predicate.beatMask(0xA5C3, 3));
    try std.testing.expectEqual(@as(u4, 0x3), predicate.beatMask(0xA5C3, 0));
}
