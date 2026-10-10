//! The DRW blend unit: what one pixel becomes when the engine draws over it.
//!
//! Split out of drw.zig because it is a different thing: drw.zig is a
//! register window and a rasterizer walking a bounding box, this is the
//! arithmetic that decides the pixel it stores. Every rule here was measured
//! on an EK-RA8D2 for the C tree's issues #247 and #170 and ported from
//! board_periph_drw.c on dev; none of it is the datasheet ideal.
//!
//! Two of those measurements are traps a driver falls into silently:
//!
//!   * The reset blend factors are fS = fD = 1, so a plain fill ADDS to what
//!     is already there. Filling 0xFF00FF00 over 0x00000010 gives 0xFF00FF10
//!     on the bench, not the colour asked for; CONTROL2.BDI is what makes it
//!     a replace.
//!   * With CONTROL2.USEACB clear the stored alpha byte does not come from
//!     the colour blend at all, it comes from the WRITEALPHA mux, and that
//!     mux resets to "take COLOR2's alpha". COLOR2 is 0 for a plain fill, so
//!     an opaque fill reads back fully transparent. That is exactly what
//!     issue #170 was.

/// CONTROL2 bit positions (HUM Ch 62.2.2 pp 3691-3694).
pub const control2 = struct {
    pub const pattern_enable: u32 = 1 << 0;
    pub const texture_enable: u32 = 1 << 1;
    /// USEACB: blend the alpha channel instead of using the WRITEALPHA mux.
    pub const use_acb: u32 = 1 << 3;
    pub const alpha_src_factor: u32 = 1 << 6;
    pub const alpha_dst_factor: u32 = 1 << 7;
    /// WRITEFORMAT[2] sits on its own, eleven bits below the low two.
    pub const format_high: u32 = 1 << 8;
    pub const src_factor: u32 = 1 << 9;
    pub const dst_factor: u32 = 1 << 10;
    pub const src_invert: u32 = 1 << 11;
    pub const dst_invert: u32 = 1 << 12;
    pub const format_low_shift: u5 = 20;
    pub const format_low_mask: u32 = 0x3;
    pub const write_alpha_shift: u5 = 22;
    pub const write_alpha_mask: u32 = 0x3;
    pub const alpha_src_invert: u32 = 1 << 28;
    pub const alpha_dst_invert: u32 = 1 << 29;
};

/// ARGB8888 channel positions, and the fixed-point constants the bench
/// composite is reproduced bit-exactly with.
pub const channel = struct {
    pub const mask: u32 = 0xFF;
    pub const alpha_shift: u5 = 24;
    pub const red_shift: u5 = 16;
    pub const green_shift: u5 = 8;
    /// Factor 1.0, expressed over 255.
    pub const one: u32 = 255;
    /// Round to nearest rather than truncate: out = (num + 127) / 255.
    pub const round: u32 = 127;
};

/// WRITEFORMAT[2:0]: the framebuffer format the engine stores through
/// (HUM Ch 62.2.2 p 3692). Codes 4..7 are prohibited and take the 32-bit
/// width on silicon, which is why they are named rather than left out.
pub const Format = enum(u3) {
    a8 = 0,
    rgb565 = 1,
    argb8888 = 2,
    argb4444 = 3,
    reserved4 = 4,
    reserved5 = 5,
    reserved6 = 6,
    reserved7 = 7,

    pub fn bytesPerPixel(self: Format) u32 {
        return switch (self) {
            .a8 => 1,
            .rgb565, .argb4444 => 2,
            else => 4,
        };
    }
};

/// WRITEALPHA[1:0]: where the stored alpha byte comes from with USEACB
/// clear (HUM Ch 62.2.2 p 3694, Figure 62.23 p 3734). Bench-measured with
/// COLOR1 = 0xFF00FF00: code 0 took COLOR2's alpha byte and COLOR2's RGB did
/// not leak into the result.
pub const WriteAlpha = enum(u2) {
    color2 = 0,
    source = 1,
    zero = 2,
    framebuffer = 3,
};

/// One blend factor, as the two CONTROL2 bits that select it.
pub const Factor = struct {
    is_alpha: bool,
    invert: bool,

    /// HUM Ch 62.6.5.1 p 3733: 1 when both bits are clear, alpha when
    /// is_alpha stands alone, 0 when invert stands alone, 1 - alpha when
    /// both are set.
    pub fn numerator(self: Factor, alpha: u32) u32 {
        if (self.is_alpha) return if (self.invert) channel.one - alpha else alpha;
        return if (self.invert) 0 else channel.one;
    }
};

/// How CONTROL2 is currently programmed, decoded once per render instead of
/// bit-twiddled per pixel.
pub const Style = struct {
    format: Format,
    write_alpha: WriteAlpha,
    blend_alpha: bool,
    src: Factor,
    dst: Factor,
    alpha_src: Factor,
    alpha_dst: Factor,
    /// A pattern source, which this model does not read: a render asking
    /// for one is declined rather than guessed at.
    patterned: bool,
    /// A texture source, which tex.zig reads for real.
    textured: bool,

    pub fn decode(word: u32) Style {
        const low = word >> control2.format_low_shift & control2.format_low_mask;
        const high: u32 = if (word & control2.format_high != 0) 0x4 else 0;
        return .{
            .format = @fromBackingInt(@intCast(@as(u3, @intCast(low | high)))),
            .write_alpha = @fromBackingInt(@intCast(@as(u2, @intCast(word >> control2.write_alpha_shift & control2.write_alpha_mask)))),
            .blend_alpha = word & control2.use_acb != 0,
            .src = .{ .is_alpha = word & control2.src_factor != 0, .invert = word & control2.src_invert != 0 },
            .dst = .{ .is_alpha = word & control2.dst_factor != 0, .invert = word & control2.dst_invert != 0 },
            .alpha_src = .{ .is_alpha = word & control2.alpha_src_factor != 0, .invert = word & control2.alpha_src_invert != 0 },
            .alpha_dst = .{ .is_alpha = word & control2.alpha_dst_factor != 0, .invert = word & control2.alpha_dst_invert != 0 },
            .patterned = word & control2.pattern_enable != 0,
            .textured = word & control2.texture_enable != 0,
        };
    }

    /// Composite COLOR1 over one destination pixel, in ARGB8888 space.
    pub fn shade(self: Style, color1: u32, color2: u32, dst: u32) u32 {
        const src_a = part(color1, channel.alpha_shift);
        const fs = self.src.numerator(src_a);
        const fd = self.dst.numerator(src_a);
        const r = mix(part(color1, channel.red_shift), part(dst, channel.red_shift), fs, fd);
        const g = mix(part(color1, channel.green_shift), part(dst, channel.green_shift), fs, fd);
        const b = mix(part(color1, 0), part(dst, 0), fs, fd);
        const a = self.alpha(src_a, part(dst, channel.alpha_shift), color2);
        return a << channel.alpha_shift | r << channel.red_shift | g << channel.green_shift | b;
    }

    /// The stored alpha byte: blended when USEACB is set, otherwise whatever
    /// the WRITEALPHA mux selects.
    pub fn alpha(self: Style, src_a: u32, dst_a: u32, color2: u32) u32 {
        if (self.blend_alpha) {
            // HUM Ch 62.6.5.2 p 3734: the same formula shape, its own factors.
            return mix(src_a, dst_a, self.alpha_src.numerator(src_a), self.alpha_dst.numerator(src_a));
        }
        return switch (self.write_alpha) {
            .color2 => part(color2, channel.alpha_shift),
            .source => src_a,
            .zero => 0,
            .framebuffer => dst_a,
        };
    }

    /// Narrow an ARGB8888 result to the programmed framebuffer format.
    pub fn pack(self: Style, argb: u32) u32 {
        const a = part(argb, channel.alpha_shift);
        const r = part(argb, channel.red_shift);
        const g = part(argb, channel.green_shift);
        const b = part(argb, 0);
        return switch (self.format) {
            .a8 => a,
            .rgb565 => (r >> 3) << 11 | (g >> 2) << 5 | b >> 3,
            .argb4444 => (a >> 4) << 12 | (r >> 4) << 8 | (g >> 4) << 4 | b >> 4,
            else => argb,
        };
    }
};

/// One 8-bit channel of an ARGB8888 word.
pub fn part(argb: u32, shift: u5) u32 {
    return argb >> shift & channel.mask;
}

/// src * fs + dst * fd for one channel, rounded to nearest and saturated.
pub fn mix(src: u32, dst: u32, fs: u32, fd: u32) u32 {
    const numerator = src * fs + dst * fd + channel.round;
    return @min(numerator / channel.one, channel.mask);
}
