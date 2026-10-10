//! Covers src/chip/periph/drw/clut.zig: the palette an indexed texture reads
//! through, its load cursor, and the two entry formats CLUTFORMAT selects.
const std = @import("std");
const ra8 = @import("ra8");

const clut = ra8.chip.periph.drw_clut;

test "a fresh palette is quiet and reads back black" {
    const table = clut.Clut{};
    try std.testing.expect(table.quiet());
    try std.testing.expectEqual(@as(u32, 0), table.lookup(0, false));
}

test "TEXCLDATA stores at the cursor and steps it on" {
    var table = clut.Clut{};
    table.setAddress(4);
    table.push(0xFF00_00FF);
    table.push(0xFF00_FF00);
    try std.testing.expectEqual(@as(u32, 0xFF00_00FF), table.lookup(4, false));
    try std.testing.expectEqual(@as(u32, 0xFF00_FF00), table.lookup(5, false));
    try std.testing.expectEqual(@as(u32, 6), table.cursor);
    try std.testing.expectEqual(@as(u32, 2), table.loaded);
    try std.testing.expect(!table.quiet());
}

test "the load cursor wraps at the end of the table" {
    var table = clut.Clut{};
    table.setAddress(clut.size.entries - 1);
    table.push(0xDEAD_BEEF);
    try std.testing.expectEqual(@as(u32, 0), table.cursor);
    try std.testing.expectEqual(@as(u32, 0xDEAD_BEEF), table.lookup(255, false));
}

test "TEXCLADDR keeps only the eight bits the table has" {
    var table = clut.Clut{};
    table.setAddress(0x1_0007);
    try std.testing.expectEqual(@as(u32, 7), table.cursor);
}

test "TEXCLOFFSET shifts every lookup and wraps with it" {
    var table = clut.Clut{};
    table.setAddress(10);
    table.push(0xFF11_2233);
    table.setOffset(8);
    try std.testing.expectEqual(@as(u32, 0xFF11_2233), table.lookup(2, false));
    table.setAddress(1);
    table.push(0xFF44_5566);
    table.setOffset(2);
    try std.testing.expectEqual(@as(u32, 0xFF44_5566), table.lookup(255, false));
}

test "a 565 palette entry widens to opaque ARGB8888" {
    var table = clut.Clut{};
    table.setAddress(0);
    table.push(0xF800);
    try std.testing.expectEqual(@as(u32, 0xFFFF_0000), table.lookup(0, true));
    try std.testing.expectEqual(@as(u32, 0xF800), table.lookup(0, false));
}

test "full 565 channels reach 0xFF, and empty ones stay 0" {
    try std.testing.expectEqual(@as(u32, 0xFFFF_FFFF), clut.expand565(0xFFFF));
    try std.testing.expectEqual(@as(u32, 0xFF00_0000), clut.expand565(0));
    try std.testing.expectEqual(@as(u32, 0xFF00_FF00), clut.expand565(0x07E0));
    try std.testing.expectEqual(@as(u32, 0xFF00_00FF), clut.expand565(0x001F));
}

test "channel widening rounds rather than truncating" {
    try std.testing.expectEqual(@as(u32, 0), clut.scale(0, 0x1F));
    try std.testing.expectEqual(@as(u32, 0xFF), clut.scale(0x1F, 0x1F));
    try std.testing.expectEqual(@as(u32, 0x88), clut.scale(0x8, 0xF));
    try std.testing.expectEqual(@as(u32, 0x84), clut.scale(0x10, 0x1F));
}
