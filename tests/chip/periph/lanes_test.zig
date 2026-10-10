//! Covers src/chip/periph/lanes.zig: the byte-lane arithmetic three peripheral
//! blocks share.
const std = @import("std");
const ra8 = @import("ra8");

const lanes = ra8.chip.periph.lanes;

test "an offset lands in the word below it, at the lane it names" {
    try std.testing.expectEqual(@as(u32, 0x20), lanes.word(0x22));
    try std.testing.expectEqual(@as(u32, 2), lanes.lane(0x22));
    try std.testing.expectEqual(@as(u32, 0x20), lanes.word(0x20));
    try std.testing.expectEqual(@as(u32, 0), lanes.lane(0x20));
}

test "a width names the bits it covers, and a word access names all of them" {
    try std.testing.expectEqual(@as(u32, 0x0000_00FF), lanes.named(0, 1));
    try std.testing.expectEqual(@as(u32, 0x0000_FF00), lanes.named(1, 1));
    try std.testing.expectEqual(@as(u32, 0x0000_FFFF), lanes.named(0, 2));
    try std.testing.expectEqual(@as(u32, 0xFFFF_0000), lanes.named(2, 2));
    try std.testing.expectEqual(~@as(u32, 0), lanes.named(0, 4));
}

test "a narrow read is the word cut to the lanes it names" {
    const value: u32 = 0x1122_3344;
    try std.testing.expectEqual(@as(u32, 0x44), lanes.part(value, 0, 1));
    // Byte index, not nibble position: byte 2 of that word is 0x22.
    try std.testing.expectEqual(@as(u32, 0x22), lanes.part(value, 2, 1));
    try std.testing.expectEqual(@as(u32, 0x3344), lanes.part(value, 0, 2));
    try std.testing.expectEqual(@as(u32, 0x1122), lanes.part(value, 2, 2));
    try std.testing.expectEqual(value, lanes.part(value, 0, 4));
}

test "a narrow store leaves the lanes it does not name where they were" {
    const current: u32 = 0x1122_3344;
    try std.testing.expectEqual(@as(u32, 0x1122_33FF), lanes.merge(current, 0, 1, 0xFF));
    try std.testing.expectEqual(@as(u32, 0x11FF_3344), lanes.merge(current, 2, 1, 0xFF));
    try std.testing.expectEqual(@as(u32, 0x1122_ABCD), lanes.merge(current, 0, 2, 0xABCD));
    try std.testing.expectEqual(@as(u32, 0xABCD_3344), lanes.merge(current, 2, 2, 0xABCD));
}

test "a word store replaces the register whatever was under it" {
    try std.testing.expectEqual(
        @as(u32, 0xDEAD_BEEF),
        lanes.merge(0x1122_3344, 0, 4, 0xDEAD_BEEF),
    );
}

test "a store wider than the lanes it names drops the bits that do not fit" {
    try std.testing.expectEqual(@as(u32, 0x0000_0012), lanes.merge(0, 0, 1, 0xAB12));
}
