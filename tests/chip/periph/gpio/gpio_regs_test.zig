//! Tests for src/chip/periph/gpio_regs.zig.
const std = @import("std");
const ra8 = @import("ra8");
const mod = ra8.chip.periph.gpio_regs;

test "every half lands in the word that carries it" {
    try std.testing.expectEqual(mod.off.pcntr1, mod.word(mod.off.pdr));
    try std.testing.expectEqual(mod.off.pcntr1, mod.word(mod.off.podr));
    try std.testing.expectEqual(mod.off.pcntr2, mod.word(mod.off.pidr));
    try std.testing.expectEqual(mod.off.pcntr2, mod.word(mod.off.eidr));
    try std.testing.expectEqual(mod.off.pcntr3, mod.word(mod.off.posr));
    try std.testing.expectEqual(mod.off.pcntr3, mod.word(mod.off.porr));
    try std.testing.expectEqual(mod.off.pcntr4, mod.word(mod.off.eosr));
    try std.testing.expectEqual(mod.off.pcntr4, mod.word(mod.off.eorr));
}

test "the lane is the byte the access starts at, not the half it names" {
    try std.testing.expectEqual(@as(u32, 0), mod.lane(mod.off.pdr));
    try std.testing.expectEqual(@as(u32, 2), mod.lane(mod.off.podr));
    try std.testing.expectEqual(@as(u32, 0), mod.lane(mod.off.pidr));
    try std.testing.expectEqual(@as(u32, 2), mod.lane(mod.off.eidr));
    try std.testing.expectEqual(@as(u32, 2), mod.lane(mod.off.porr));
}

test "PCNTR2 is the only word the port owns" {
    try std.testing.expect(mod.readOnly(mod.off.pcntr2));
    try std.testing.expect(!mod.readOnly(mod.off.pcntr1));
    try std.testing.expect(!mod.readOnly(mod.off.pcntr3));
    try std.testing.expect(!mod.readOnly(mod.off.pcntr4));
}

test "a narrow read names its own lanes, little-endian" {
    const value: u32 = 0x1122_3344;
    try std.testing.expectEqual(@as(u32, 0x1122_3344), mod.part(value, 0, 4));
    try std.testing.expectEqual(@as(u32, 0x3344), mod.part(value, 0, 2));
    try std.testing.expectEqual(@as(u32, 0x1122), mod.part(value, 2, 2));
    try std.testing.expectEqual(@as(u32, 0x44), mod.part(value, 0, 1));
    try std.testing.expectEqual(@as(u32, 0x33), mod.part(value, 1, 1));
    try std.testing.expectEqual(@as(u32, 0x11), mod.part(value, 3, 1));
}

test "a narrow store leaves the bytes it does not name alone" {
    const current: u32 = 0x1122_3344;
    try std.testing.expectEqual(@as(u32, 0x1122_BEEF), mod.merge(current, 0, 2, 0xBEEF));
    try std.testing.expectEqual(@as(u32, 0xBEEF_3344), mod.merge(current, 2, 2, 0xBEEF));
    try std.testing.expectEqual(@as(u32, 0x1122_33AA), mod.merge(current, 0, 1, 0xAA));
    try std.testing.expectEqual(@as(u32, 0x11AA_3344), mod.merge(current, 2, 1, 0xAA));
}

test "a word-wide store replaces the whole register" {
    try std.testing.expectEqual(@as(u32, 0xDEAD_BEEF), mod.merge(0x1122_3344, 0, 4, 0xDEAD_BEEF));
}

test "a narrow store keeps only the bits its width carries" {
    try std.testing.expectEqual(@as(u32, 0x1122_3399), mod.merge(0x1122_3344, 0, 1, 0xFF99));
}
