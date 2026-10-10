//! One texel: what a texture format is, how wide it is, and the ARGB8888
//! colour a raw texel word means.
//!
//! Split out of tex.zig because it is a different thing: that file
//! generates coordinates and owns registers, this is the pixel format table
//! and nothing else. The codes are CONTROL2.READFORMAT, a four-bit field
//! split across bits 5:4 and 19:18 (ra8_drw_regs.h `ra8_drw_readformat_t`,
//! HUM Ch 62.2.2 p 3692), so a driver writing one register writes both
//! halves and this reassembles them.
//!
//! Sub-byte formats (CLUT1/2/4) are the reason a texel is addressed in bits
//! rather than bytes: four I4 texels share a byte, and which nibble a texel
//! lands in is its index's low bit, not a separate register.
const std = @import("std");

const clut = @import("clut.zig");

/// CONTROL2's READFORMAT halves.
pub const field = struct {
    pub const high_shift: u5 = 4;
    pub const high_mask: u32 = 0x3;
    pub const low_shift: u5 = 18;
    pub const low_mask: u32 = 0x3;
    pub const high_position: u5 = 2;
};

/// Texture pixel formats. Non-exhaustive because codes 6, 7, 8 and 0xD..0xF
/// are undocumented, and a render asking for one is declined rather than
/// read as something adjacent.
pub const Format = enum(u4) {
    a8 = 0x0,
    rgb565 = 0x1,
    argb8888 = 0x2,
    argb4444 = 0x3,
    argb1555 = 0x4,
    aclut44 = 0x5,
    clut8 = 0x9,
    clut4 = 0xA,
    clut2 = 0xB,
    clut1 = 0xC,
    _,

    /// READFORMAT as the two CONTROL2 halves put it together.
    pub fn decode(control2: u32) Format {
        const high = control2 >> field.high_shift & field.high_mask;
        const low = control2 >> field.low_shift & field.low_mask;
        return @fromBackingInt(@intCast(@as(u4, @intCast(high << field.high_position | low))));
    }

    /// Bits per texel, or null for a code with no documented width.
    pub fn bits(self: Format) ?u32 {
        return switch (self) {
            .a8, .aclut44, .clut8 => 8,
            .rgb565, .argb4444, .argb1555 => 16,
            .argb8888 => 32,
            .clut4 => 4,
            .clut2 => 2,
            .clut1 => 1,
            _ => null,
        };
    }

    /// Whether the texel carries a palette index rather than a colour.
    pub fn indexed(self: Format) bool {
        return switch (self) {
            .aclut44, .clut8, .clut4, .clut2, .clut1 => true,
            else => false,
        };
    }

    /// The palette index inside a raw texel. ACLUT44 keeps its alpha in the
    /// high nibble and indexes with the low one.
    pub fn index(self: Format, raw: u32) u32 {
        return switch (self) {
            .aclut44 => raw & 0xF,
            else => raw,
        };
    }

    /// The alpha an indexed texel carries itself, or null when the palette
    /// entry is the only source of alpha.
    pub fn carriedAlpha(self: Format, raw: u32) ?u32 {
        return switch (self) {
            .aclut44 => clut.scale(raw >> 4 & 0xF, 0xF),
            else => null,
        };
    }

    /// A direct texel as ARGB8888. Indexed formats never reach here.
    pub fn expand(self: Format, raw: u32) u32 {
        return switch (self) {
            .a8 => raw << 24,
            .rgb565 => clut.expand565(raw),
            .argb8888 => raw,
            .argb4444 => expand4444(raw),
            .argb1555 => expand1555(raw),
            else => 0,
        };
    }
};

/// ARGB4444 widened a nibble at a time.
pub fn expand4444(raw: u32) u32 {
    var out: u32 = 0;
    var lane: u5 = 0;
    while (lane < 4) : (lane += 1) {
        const nibble = raw >> (lane * 4) & 0xF;
        out |= clut.scale(nibble, 0xF) << (lane * 8);
    }
    return out;
}

/// ARGB1555: one alpha bit, five bits a channel.
pub fn expand1555(raw: u32) u32 {
    const a: u32 = if (raw & 0x8000 != 0) 0xFF else 0;
    const r = clut.scale(raw >> 10 & 0x1F, 0x1F);
    const g = clut.scale(raw >> 5 & 0x1F, 0x1F);
    const b = clut.scale(raw & 0x1F, 0x1F);
    return a << 24 | r << 16 | g << 8 | b;
}

/// Where texel number `at` starts, in bits from TEXORIGIN.
pub fn bitOffset(width: u32, at: u64) u64 {
    return at * width;
}

/// Pull one texel out of the bytes that hold it. `bytes` is the four-byte
/// window starting at the texel's own byte, little-endian, and `shift` is
/// how far into that first byte a sub-byte texel sits.
pub fn extract(width: u32, shift: u3, bytes: [4]u8) u32 {
    var word: u32 = 0;
    for (bytes, 0..) |byte, lane| word |= @as(u32, byte) << @intCast(lane * 8);
    const mask: u32 = if (width >= 32) std.math.maxInt(u32) else (@as(u32, 1) << @intCast(width)) - 1;
    return word >> shift & mask;
}
