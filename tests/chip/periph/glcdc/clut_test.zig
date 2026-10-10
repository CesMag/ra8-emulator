//! Covers src/chip/periph/glcdc/clut.zig: the four CLUT planes the display
//! controller looks a CLUT-mode pixel up in, and which plane it reads.
const std = @import("std");
const ra8 = @import("ra8");

const clut = ra8.chip.periph.glcdc_clut;

test "an offset inside the CLUT area names its layer, plane and entry" {
    const first = clut.slotOf(0x0000).?;
    try std.testing.expectEqual(@as(u8, 1), first.layer);
    try std.testing.expectEqual(@as(u8, 0), first.plane);
    try std.testing.expectEqual(@as(u32, 0), first.index);

    const second_plane = clut.slotOf(0x0400 + 4 * 3).?;
    try std.testing.expectEqual(@as(u8, 1), second_plane.layer);
    try std.testing.expectEqual(@as(u8, 1), second_plane.plane);
    try std.testing.expectEqual(@as(u32, 3), second_plane.index);

    const layer2 = clut.slotOf(0x0800 + 4 * 255).?;
    try std.testing.expectEqual(@as(u8, 2), layer2.layer);
    try std.testing.expectEqual(@as(u8, 0), layer2.plane);
    try std.testing.expectEqual(@as(u32, 255), layer2.index);

    const layer2_second = clut.slotOf(0x0C00).?;
    try std.testing.expectEqual(@as(u8, 2), layer2_second.layer);
    try std.testing.expectEqual(@as(u8, 1), layer2_second.plane);
}

test "the BG block is past the CLUT area" {
    try std.testing.expect(clut.slotOf(0x1000) == null);
    try std.testing.expect(clut.slotOf(clut.geometry.end) == null);
    try std.testing.expect(clut.slotOf(clut.geometry.end - 4) != null);
}

test "an entry keeps what was stored and the fill count is entries, not writes" {
    var palette = clut.Palette{};
    try std.testing.expect(palette.quiet());
    palette.store(0, 7, 0xFF00_FF00);
    palette.store(0, 7, 0xFF00_FF00);
    try std.testing.expectEqual(@as(u32, 1), palette.filled[0]);
    try std.testing.expectEqual(@as(u32, 0xFF00_FF00), palette.load(0, 7));
    try std.testing.expect(!palette.quiet());
}

test "an entry past the palette is not stored and reads as zero" {
    var palette = clut.Palette{};
    palette.store(0, clut.geometry.entries, 0xFFFF_FFFF);
    palette.store(clut.geometry.planes, 0, 0xFFFF_FFFF);
    try std.testing.expectEqual(@as(u32, 0), palette.filled[0]);
    try std.testing.expectEqual(@as(u32, 0), palette.load(0, clut.geometry.entries));
}

test "CLUTINT.SEL picks the plane the fetch unit reads" {
    var palette = clut.Palette{};
    palette.store(0, 1, 0xFF11_1111);
    palette.store(1, 1, 0xFF22_2222);
    try std.testing.expectEqual(@as(u32, 0xFF11_1111), palette.colour(1));
    palette.select(clut.clutint.sel);
    try std.testing.expectEqual(@as(u8, 1), palette.selected);
    try std.testing.expectEqual(@as(u32, 0xFF22_2222), palette.colour(1));
    palette.select(0);
    try std.testing.expectEqual(@as(u32, 0xFF11_1111), palette.colour(1));
}

test "a plane nobody filled is not a programmed palette" {
    var palette = clut.Palette{};
    try std.testing.expect(!palette.programmed());
    palette.store(0, 0, 0xFF00_0000);
    try std.testing.expect(palette.programmed());
    // The other plane is still empty, so selecting it is still unprogrammed.
    palette.select(clut.clutint.sel);
    try std.testing.expect(!palette.programmed());
}

test "a zero written into an entry is a colour, not a fill" {
    var palette = clut.Palette{};
    palette.store(0, 0, 0);
    try std.testing.expectEqual(@as(u32, 0), palette.filled[0]);
    try std.testing.expect(!palette.programmed());
}
