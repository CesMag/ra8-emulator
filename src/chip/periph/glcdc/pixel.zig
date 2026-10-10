//! Turning a fetched framebuffer pixel into a colour.
//!
//! FLM6.FORMAT names eight packings (HUM Ch 63 Table 63.11). Five carry the
//! colour in the pixel itself; three carry an index into the layer's CLUT.
//! dev has the eight codes as an enum and uses them for exactly two things,
//! a bytes-per-pixel number and a name in the report, so a framebuffer's
//! contents were never decoded at all.
//!
//! The bytes-per-pixel number is where that bites. dev rounds CLUT4 and
//! CLUT1 up to one byte per pixel and then recovers the panel width as
//! `stride / bytes`, so a 4-bit layer reads back half as wide as it is and a
//! 1-bit layer an eighth. The width is in the report, and it is wrong for
//! every sub-byte layer dev has ever printed. Bits, not bytes, is the unit
//! that works for all eight.
const clut = @import("clut.zig");

/// FLM6.FORMAT codes. A real enumeration: these are the eight packings the
/// fetch unit understands and nothing else.
pub const Format = enum(u3) {
    argb8888 = 0,
    rgb888 = 1,
    rgb565 = 2,
    argb1555 = 3,
    argb4444 = 4,
    clut8 = 5,
    clut4 = 6,
    clut1 = 7,

    /// Bits one pixel occupies in memory. This is the honest unit: the three
    /// CLUT modes are 8, 4 and 1, and only the first of them is a byte.
    pub fn bits(self: Format) u32 {
        return switch (self) {
            .argb8888, .rgb888 => 32,
            .rgb565, .argb1555, .argb4444 => 16,
            .clut8 => 8,
            .clut4 => 4,
            .clut1 => 1,
        };
    }

    /// Bytes fetched per pixel, sub-byte modes rounded up to one. Kept
    /// because the descriptor's own sanity check reads in these terms, and
    /// so a reader comparing against dev's decode sees the same number.
    pub fn bytesPerPixel(self: Format) u32 {
        return (self.bits() + 7) / 8;
    }

    /// Whether the pixel is an index into the layer's palette rather than a
    /// colour.
    pub fn indexed(self: Format) bool {
        return switch (self) {
            .clut8, .clut4, .clut1 => true,
            else => false,
        };
    }

    /// How many pixels a line of `stride` bytes carries.
    pub fn pixelsIn(self: Format, stride: u32) u32 {
        return stride * 8 / self.bits();
    }

    /// The decoder for this packing.
    pub fn decoder(self: Format) *const fn (raw: u32, palette: *const clut.Palette) u32 {
        return switch (self) {
            .argb8888 => argb8888,
            .rgb888 => rgb888,
            .rgb565 => rgb565,
            .argb1555 => argb1555,
            .argb4444 => argb4444,
            .clut8, .clut4, .clut1 => indexedColour,
        };
    }
};

/// Already ARGB8888: the fetch is the colour.
pub fn argb8888(raw: u32, palette: *const clut.Palette) u32 {
    _ = palette;
    return raw;
}

/// Four bytes fetched, three of them colour. The top byte is not alpha and
/// is not the driver's: an RGB888 layer is opaque.
pub fn rgb888(raw: u32, palette: *const clut.Palette) u32 {
    _ = palette;
    return 0xFF00_0000 | (raw & 0x00FF_FFFF);
}

pub fn rgb565(raw: u32, palette: *const clut.Palette) u32 {
    _ = palette;
    return 0xFF00_0000 |
        scale(raw >> 11 & 0x1F, 5) << 16 |
        scale(raw >> 5 & 0x3F, 6) << 8 |
        scale(raw & 0x1F, 5);
}

pub fn argb1555(raw: u32, palette: *const clut.Palette) u32 {
    _ = palette;
    const alpha: u32 = if (raw & 0x8000 != 0) 0xFF else 0;
    return alpha << 24 |
        scale(raw >> 10 & 0x1F, 5) << 16 |
        scale(raw >> 5 & 0x1F, 5) << 8 |
        scale(raw & 0x1F, 5);
}

pub fn argb4444(raw: u32, palette: *const clut.Palette) u32 {
    _ = palette;
    return scale(raw >> 12 & 0xF, 4) << 24 |
        scale(raw >> 8 & 0xF, 4) << 16 |
        scale(raw >> 4 & 0xF, 4) << 8 |
        scale(raw & 0xF, 4);
}

/// CLUT8 / CLUT4 / CLUT1: the fetch is an index, the colour is the
/// palette's. The three differ only in how many bits the fetch took, which
/// the line reader has already dealt with by the time the index arrives.
pub fn indexedColour(raw: u32, palette: *const clut.Palette) u32 {
    return palette.colour(raw);
}

/// Widen an n-bit channel to eight bits by repeating its top bits, so full
/// scale stays full scale. Shared with the drawing engine's own expansion,
/// which reached the same place from the other side of the framebuffer.
pub fn scale(value: u32, width: u5) u32 {
    const shift: u5 = @intCast(8 - @as(u32, width));
    return value << shift | value >> @intCast(@as(u32, width) - shift);
}
