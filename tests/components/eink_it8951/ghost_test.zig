//! Fast-waveform ghosting: DU and A2 leave a faint residue of the
//! previous image, and GC16 or INIT clears it (RA8EMU-559).
const std = @import("std");
const ra8 = @import("ra8");
const image = ra8.components.eink.image;
const waveform = ra8.components.eink.wire.waveform;

test "a DU flip keeps an eighth of the old level as residue" {
    try std.testing.expectEqual(@as(u8, 0x1F), image.waveformPixel(0x00, 0xFF, waveform.du));
    try std.testing.expectEqual(@as(u8, 0xE0), image.waveformPixel(0xFF, 0x00, waveform.du));
    try std.testing.expectEqual(@as(u8, 0x10), image.waveformPixel(0x00, 0x80, waveform.a2_m641));
}

test "a pixel within reach of its fast target is left undriven" {
    try std.testing.expectEqual(@as(u8, 0x1F), image.waveformPixel(0x00, 0x1F, waveform.du));
    try std.testing.expectEqual(@as(u8, 0xE0), image.waveformPixel(0xFF, 0xE0, waveform.a2_generic));
    try std.testing.expectEqual(@as(u8, 0x00), image.waveformPixel(0x00, 0x00, waveform.du));
}

test "GC16 and INIT leave no residue" {
    try std.testing.expectEqual(@as(u8, 0x00), image.waveformPixel(0x00, 0x1F, waveform.gc16));
    try std.testing.expectEqual(@as(u8, 0xFF), image.waveformPixel(0xFF, 0xE0, waveform.gc16));
    try std.testing.expectEqual(@as(u8, 0xFF), image.waveformPixel(0x00, 0x1F, waveform.init));
}

fn plane(pixels: []u8) image.Buffer {
    return .{ .width = @intCast(pixels.len), .height = 1, .pixels = pixels };
}

test "residue survives repeated DU refreshes until a GC16 clears it" {
    var white = [_]u8{ 0xFF, 0xFF };
    var black = [_]u8{ 0x00, 0x00 };
    var glass_pixels = [_]u8{ 0xFF, 0x00 };
    const white_plane = plane(&white);
    const black_plane = plane(&black);
    var glass = plane(&glass_pixels);

    glass.refreshFrom(&black_plane, 0, 0, 2, 1, waveform.du);
    try std.testing.expectEqualSlices(u8, &.{ 0x1F, 0x00 }, glass.pixels);
    glass.refreshFrom(&black_plane, 0, 0, 2, 1, waveform.du);
    try std.testing.expectEqualSlices(u8, &.{ 0x1F, 0x00 }, glass.pixels);
    glass.refreshFrom(&black_plane, 0, 0, 2, 1, waveform.gc16);
    try std.testing.expectEqualSlices(u8, &.{ 0x00, 0x00 }, glass.pixels);
    glass.refreshFrom(&white_plane, 0, 0, 2, 1, waveform.du);
    try std.testing.expectEqualSlices(u8, &.{ 0xE0, 0xE0 }, glass.pixels);
    glass.refreshFrom(&white_plane, 0, 0, 2, 1, waveform.init);
    try std.testing.expectEqualSlices(u8, &.{ 0xFF, 0xFF }, glass.pixels);
}
