//! The graphics layers' blend stage: which of the two layers reaches the
//! panel, where each one sits on it, and what happens where they overlap.
//!
//! Each graphics layer carries nine AB registers and a BASE colour past the
//! framebuffer descriptor (ra8_glcdc_regs.h, GR1 +0x1120..+0x114C, GR2 one
//! layer stride above). They decide the whole of what a viewer sees:
//!
//!   AB1  DISPSEL [1:0]  what this layer contributes: nothing, its own BASE
//!                       colour, its framebuffer, or its framebuffer blended
//!                       over whatever is under it
//!        GRCDISPON b4   a frame line drawn round the rectangle (not
//!                       modelled; it never gates the layer)
//!        ARCON    b12   the alpha rectangle narrows the blend further
//!   AB2  GRCVS [26:16] / GRCVW [10:0]   rectangle top edge and height
//!   AB3  GRCHS [26:16] / GRCHW [10:0]   rectangle left edge and width
//!   AB4  ARCVS / ARCVW                  alpha rectangle, vertically
//!   AB5  ARCHS / ARCHW                  alpha rectangle, horizontally
//!
//! The edges are counted the way the timing generator counts, from the
//! sync pulse's end: ra8_glcdc.c writes (h_back << 16) | fb_w into AB3 to
//! put a framebuffer at the panel's first column, so the panel origin is
//! the back porch TCON was given.
//!   AB6  ARCRATE [23:16] / ARCCOEF      fade rate and coefficient
//!   AB7  ARCDEF [23:16] the alpha applied where the pixel carries none
//!        CKON     b0    chroma keying on
//!   AB8  CKKR/CKKG/CKKB the key colour, matched against the source RGB
//!   AB9  CKA/CKR/CKG/CKB what a keyed pixel becomes instead
//!
//! dev models none of it. Its GLCDC snoops five descriptor offsets per layer
//! and picks GR1 whenever GR1.FLMRD is set, GR2 otherwise, so a layer the
//! driver deliberately hid (DISPSEL = 0) is still reported as the picture, a
//! second layer over the first is never in the witness at all, and a layer
//! positioned at a corner of the panel is reported as though it covered the
//! whole of it.
const std = @import("std");

/// AB register offsets inside one graphics layer, from the layer's base.
pub const off = struct {
    pub const ab1: u32 = 0x20;
    pub const ab2: u32 = 0x24;
    pub const ab3: u32 = 0x28;
    pub const ab4: u32 = 0x2C;
    pub const ab5: u32 = 0x30;
    pub const ab6: u32 = 0x34;
    pub const ab7: u32 = 0x38;
    pub const ab8: u32 = 0x3C;
    pub const ab9: u32 = 0x40;
    /// BASE: the colour the layer shows where it has no framebuffer pixel.
    pub const base: u32 = 0x4C;
};

/// Field positions the blend stage reads out of those registers.
pub const field = struct {
    pub const dispsel: u32 = 0x3;
    pub const grcdispon: u32 = 1 << 4;
    pub const arcon: u32 = 1 << 12;
    /// A position and size pair: start in [26:16], size in [10:0].
    pub const start_shift: u5 = 16;
    pub const size_mask: u32 = 0x7FF;
    pub const start_mask: u32 = 0x7FF;
    /// AB7.ARCDEF, the alpha a pixel gets when its format carries none.
    pub const arcdef_shift: u5 = 16;
    pub const arcdef_mask: u32 = 0xFF;
    /// AB7.CKON.
    pub const ckon: u32 = 1 << 0;
    /// AB8 and AB9 carry colour channels in the usual ARGB byte order.
    pub const rgb_mask: u32 = 0x00FF_FFFF;
};

/// AB1.DISPSEL: what this layer puts on the panel. The codes are the ones
/// ra8_glcdc_layer.c writes by name (k_ra8_glcdc_dispsel_below = 1,
/// k_ra8_glcdc_dispsel_above = 2, and 3 where it calls FSP's
/// BLEND_ON_LOWER_LAYER).
pub const Display = enum(u2) {
    /// The background screen colour. The in-tree driver never selects it.
    background = 0,
    /// Transparent: this layer stands aside and the layer below shows.
    transparent = 1,
    /// This layer's framebuffer, displayed as it is, no blending.
    shown = 2,
    /// This layer's framebuffer blended onto the layer below it by alpha.
    blended = 3,
};

/// A rectangle on the panel, in pixels.
pub const Rect = struct {
    left: u32 = 0,
    top: u32 = 0,
    width: u32 = 0,
    height: u32 = 0,

    /// Whether a panel coordinate falls inside. A zero-sized rectangle
    /// covers nothing, which is what an unprogrammed AB2/AB3 pair means.
    pub fn covers(self: Rect, column: u32, row: u32) bool {
        if (self.width == 0 or self.height == 0) return false;
        return column >= self.left and column < self.left + self.width and
            row >= self.top and row < self.top + self.height;
    }

    /// The pair packed in one AB register: start in [26:16], size in [10:0].
    pub fn fromPair(vertical: u32, horizontal: u32) Rect {
        return .{
            .left = horizontal >> field.start_shift & field.start_mask,
            .top = vertical >> field.start_shift & field.start_mask,
            .width = horizontal & field.size_mask,
            .height = vertical & field.size_mask,
        };
    }

    /// The rectangle counted from the panel's first active pixel instead
    /// of from the sync pulse. Whatever part starts in the porch is lost.
    pub fn from(self: Rect, origin: Origin) Rect {
        return .{
            .left = self.left -| origin.left,
            .top = self.top -| origin.top,
            .width = self.width -| (origin.left -| self.left),
            .height = self.height -| (origin.top -| self.top),
        };
    }
};

/// Where the panel's first active pixel sits in the counter the AB
/// registers are written against: the horizontal and vertical back porch.
pub const Origin = struct {
    left: u32 = 0,
    top: u32 = 0,
};

/// One layer's blend configuration, latched as the driver programs it.
pub const Layer = struct {
    ab1: u32 = 0,
    ab2: u32 = 0,
    ab3: u32 = 0,
    ab4: u32 = 0,
    ab5: u32 = 0,
    ab7: u32 = 0,
    ab8: u32 = 0,
    ab9: u32 = 0,
    /// GRn_BASE, the layer's own background colour.
    base_colour: u32 = 0,
    /// The panel origin in AB coordinates, set by the GLCDC from TCON.
    origin: Origin = .{},
    /// Built by `implied`, so its rectangle already sits at the origin.
    implicit: bool = false,
    /// Pixels this layer handed to the panel.
    shown: u32 = 0,
    /// Pixels the chroma key replaced.
    keyed: u32 = 0,
    /// Pixels inside the rectangle that the blend dropped, alpha and all.
    hidden: u32 = 0,

    /// Take a write aimed at this layer's blend registers. False when the
    /// offset belongs to the descriptor instead, so the caller goes on.
    pub fn latch(self: *Layer, offset: u32, value: u32) bool {
        switch (offset) {
            off.ab1 => self.ab1 = value,
            off.ab2 => self.ab2 = value,
            off.ab3 => self.ab3 = value,
            off.ab4 => self.ab4 = value,
            off.ab5 => self.ab5 = value,
            off.ab7 => self.ab7 = value,
            off.ab8 => self.ab8 = value,
            off.ab9 => self.ab9 = value,
            off.base => self.base_colour = value,
            else => return false,
        }
        if (offset == off.ab2 or offset == off.ab3) self.implicit = false;
        return true;
    }

    pub fn display(self: Layer) Display {
        return @fromBackingInt(@intCast(self.ab1 & field.dispsel));
    }

    /// AB1.GRCDISPON: whether the rectangle's frame line is drawn. The
    /// in-tree driver never sets it and the layer shows either way.
    pub fn framed(self: Layer) bool {
        return self.ab1 & field.grcdispon != 0;
    }

    /// The rectangle the layer occupies on the panel.
    pub fn rect(self: Layer) Rect {
        return self.placed(self.ab2, self.ab3);
    }

    /// The alpha rectangle, which narrows the blend inside the layer's own
    /// rectangle. Only consulted when AB1.ARCON is set.
    pub fn alphaRect(self: Layer) Rect {
        return self.placed(self.ab4, self.ab5);
    }

    fn placed(self: Layer, vertical: u32, horizontal: u32) Rect {
        const raw = Rect.fromPair(vertical, horizontal);
        return if (self.implicit) raw else raw.from(self.origin);
    }

    pub fn alphaRectOn(self: Layer) bool {
        return self.ab1 & field.arcon != 0;
    }

    /// AB7.ARCDEF: the alpha a pixel is given when its format carries none,
    /// and the alpha the alpha rectangle applies.
    pub fn defaultAlpha(self: Layer) u32 {
        return self.ab7 >> field.arcdef_shift & field.arcdef_mask;
    }

    pub fn keyOn(self: Layer) bool {
        return self.ab7 & field.ckon != 0;
    }

    /// A keyed pixel's replacement, or null when the colour is not the key.
    pub fn keyReplace(self: Layer, colour: u32) ?u32 {
        if (!self.keyOn()) return null;
        if (colour & field.rgb_mask != self.ab8 & field.rgb_mask) return null;
        return self.ab9;
    }

    /// What this layer contributes at one panel coordinate, given the pixel
    /// its framebuffer holds there. Null means it contributes nothing and
    /// whatever is under it shows through.
    ///
    /// GRn_BASE is latched and reads back, and is deliberately not painted:
    /// outside its image rectangle the in-tree driver leaves a layer
    /// standing aside, and painting a plane colour there would blanket the
    /// layer below it.
    pub fn contribution(self: *Layer, colour: ?u32, column: u32, row: u32) ?u32 {
        if (!self.rect().covers(column, row)) return null;
        const mode = self.display();
        if (mode == .background or mode == .transparent) {
            self.hidden += 1;
            return null;
        }
        const fetched = colour orelse return null;
        const keyed = self.keyReplace(fetched);
        if (keyed != null) self.keyed += 1;
        const shown = self.withAlpha(keyed orelse fetched, mode, column, row);
        if (shown >> 24 == 0) {
            self.hidden += 1;
            return null;
        }
        self.shown += 1;
        return shown;
    }

    /// The alpha the blend stage actually applies to one pixel: full where
    /// the layer is displayed rather than blended, the pixel's own alpha
    /// where it is blended, and ARCDEF where the alpha rectangle covers it
    /// or the format carries no alpha of its own.
    fn withAlpha(self: Layer, colour: u32, mode: Display, column: u32, row: u32) u32 {
        if (mode != .blended) return opaqueColour(colour);
        if (self.alphaRectOn() and self.alphaRect().covers(column, row)) {
            return colour & field.rgb_mask | self.defaultAlpha() << 24;
        }
        if (colour >> 24 != 0) return colour;
        return colour & field.rgb_mask | self.defaultAlpha() << 24;
    }

    pub fn quiet(self: Layer) bool {
        return self.ab1 == 0 and self.ab2 == 0 and self.ab3 == 0 and self.base_colour == 0;
    }
};

/// The blend stage a layer with no AB register ever written implies: driven,
/// displayed rather than blended, over the whole of its framebuffer at the
/// panel's origin. No in-tree app is obliged to program the AB registers,
/// and one that does not still expects its framebuffer on the panel.
pub fn implied(width: u32, height: u32) Layer {
    return .{
        .ab1 = field.grcdispon | @backingInt(Display.shown),
        .ab2 = height & field.size_mask,
        .ab3 = width & field.size_mask,
        .implicit = true,
    };
}

/// Tell every layer where the panel's first active pixel sits, so a layer
/// the scan does not fetch still reports its rectangle on the panel.
pub fn placeAll(layers: []Layer, origin: Origin) void {
    for (layers) |*layer| layer.origin = origin;
}

/// The same colour, fully opaque.
pub fn opaqueColour(colour: u32) u32 {
    return colour & field.rgb_mask | 0xFF00_0000;
}

/// Source-over: `top` composited onto `bottom` by the top pixel's alpha.
/// Both are ARGB8888 and the result is opaque, because the panel is.
pub fn over(top: u32, bottom: u32) u32 {
    const alpha = top >> 24;
    if (alpha == 0) return bottom;
    if (alpha == 0xFF) return opaqueColour(top);
    var out: u32 = 0xFF00_0000;
    for ([_]u5{ 0, 8, 16 }) |shift| {
        const a = top >> shift & 0xFF;
        const b = bottom >> shift & 0xFF;
        const mixed = (a * alpha + b * (255 - alpha) + 127) / 255;
        out |= @as(u32, @min(mixed, 0xFF)) << shift;
    }
    return out;
}
