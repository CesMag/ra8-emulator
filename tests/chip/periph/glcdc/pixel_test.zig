//! Covers src/chip/periph/glcdc/pixel.zig: the eight FLM6.FORMAT packings and
//! the colour each one decodes to.
const std = @import("std");
const ra8 = @import("ra8");

const pixel = ra8.chip.periph.glcdc.pixel;
const clut = ra8.chip.periph.glcdc.clut;

const Format = pixel.Format;

fn emptyPalette() clut.Palette {
    return .{};
}

test "bits per pixel is the honest unit for all eight formats" {
    try std.testing.expectEqual(@as(u32, 32), Format.argb8888.bits());
    try std.testing.expectEqual(@as(u32, 32), Format.rgb888.bits());
    try std.testing.expectEqual(@as(u32, 16), Format.rgb565.bits());
    try std.testing.expectEqual(@as(u32, 16), Format.argb1555.bits());
    try std.testing.expectEqual(@as(u32, 16), Format.argb4444.bits());
    try std.testing.expectEqual(@as(u32, 8), Format.clut8.bits());
    try std.testing.expectEqual(@as(u32, 4), Format.clut4.bits());
    try std.testing.expectEqual(@as(u32, 1), Format.clut1.bits());
}

test "a sub-byte line carries more pixels than it has bytes" {
    // This is the number dev gets wrong: it divides by a bytes-per-pixel
    // that rounds CLUT4 and CLUT1 up to one, so a 100-byte CLUT4 line reads
    // back as 100 pixels there and 200 here.
    try std.testing.expectEqual(@as(u32, 100), Format.clut8.pixelsIn(100));
    try std.testing.expectEqual(@as(u32, 200), Format.clut4.pixelsIn(100));
    try std.testing.expectEqual(@as(u32, 800), Format.clut1.pixelsIn(100));
    try std.testing.expectEqual(@as(u32, 50), Format.rgb565.pixelsIn(100));
    try std.testing.expectEqual(@as(u32, 25), Format.argb8888.pixelsIn(100));
}

test "bytes per pixel still rounds up, for the descriptor's own sanity check" {
    try std.testing.expectEqual(@as(u32, 4), Format.argb8888.bytesPerPixel());
    try std.testing.expectEqual(@as(u32, 2), Format.rgb565.bytesPerPixel());
    try std.testing.expectEqual(@as(u32, 1), Format.clut4.bytesPerPixel());
    try std.testing.expectEqual(@as(u32, 1), Format.clut1.bytesPerPixel());
}

test "only the three CLUT formats look a colour up" {
    try std.testing.expect(Format.clut8.indexed());
    try std.testing.expect(Format.clut4.indexed());
    try std.testing.expect(Format.clut1.indexed());
    try std.testing.expect(!Format.argb8888.indexed());
    try std.testing.expect(!Format.argb4444.indexed());
}

test "ARGB8888 is already the colour" {
    var palette = emptyPalette();
    try std.testing.expectEqual(@as(u32, 0x8012_3456), pixel.argb8888(0x8012_3456, &palette));
}

test "an RGB888 layer is opaque whatever the fourth byte held" {
    var palette = emptyPalette();
    try std.testing.expectEqual(@as(u32, 0xFF12_3456), pixel.rgb888(0x0012_3456, &palette));
    try std.testing.expectEqual(@as(u32, 0xFF12_3456), pixel.rgb888(0x7712_3456, &palette));
}

test "RGB565 full scale stays full scale" {
    var palette = emptyPalette();
    try std.testing.expectEqual(@as(u32, 0xFFFF_FFFF), pixel.rgb565(0xFFFF, &palette));
    try std.testing.expectEqual(@as(u32, 0xFF00_0000), pixel.rgb565(0x0000, &palette));
    // Pure red: the top five bits.
    try std.testing.expectEqual(@as(u32, 0xFFFF_0000), pixel.rgb565(0xF800, &palette));
}

test "ARGB1555 carries one bit of alpha" {
    var palette = emptyPalette();
    try std.testing.expectEqual(@as(u32, 0xFFFF_FFFF), pixel.argb1555(0xFFFF, &palette));
    // Same colour, alpha bit clear: fully transparent.
    try std.testing.expectEqual(@as(u32, 0x00FF_FFFF), pixel.argb1555(0x7FFF, &palette));
}

test "ARGB4444 widens each nibble to a byte" {
    var palette = emptyPalette();
    try std.testing.expectEqual(@as(u32, 0xFFFF_FFFF), pixel.argb4444(0xFFFF, &palette));
    try std.testing.expectEqual(@as(u32, 0x8899_AABB), pixel.argb4444(0x89AB, &palette));
}

test "a CLUT pixel is an index into the selected plane" {
    var palette = emptyPalette();
    palette.store(0, 5, 0xFF00_00FF);
    try std.testing.expectEqual(@as(u32, 0xFF00_00FF), pixel.indexedColour(5, &palette));
    try std.testing.expectEqual(@as(u32, 0), pixel.indexedColour(6, &palette));
}

test "every format hands back a decoder that agrees with itself" {
    var palette = emptyPalette();
    palette.store(0, 1, 0xFF33_4455);
    try std.testing.expectEqual(
        @as(u32, 0xFF33_4455),
        Format.clut4.decoder()(1, &palette),
    );
    try std.testing.expectEqual(
        @as(u32, 0xFF00_0000),
        Format.rgb565.decoder()(0, &palette),
    );
}
