//! The DRW spatial limiters: which pixels of the bounding box the engine is
//! allowed to touch.
//!
//! drw.zig scans a bounding box; this decides, per pixel, whether the box is
//! actually painted there. Six edge limiters (HUM Ch 62.2.10-62.2.12,
//! LnSTART/LnXADD/LnYADD pp 3698-3699) each carry a linear form
//!
//!     value(x, y) = START + x * XADD + y * YADD
//!
//! in the 4-bit sub-pixel fixed point the HAL writes (ra8_drw_regs.h,
//! `k_ra8_drw_subpixel_unit` = 16). A limiter admits the half-plane where its
//! value is not negative, and CONTROL's union bits combine the six into one
//! answer down a fixed tree (HUM Ch 62.2.1 p 3689): L1/L2 -> A, L3/L4 -> B,
//! L5/L6 -> D, A/B -> C, C/D -> the final coverage. Every pair intersects
//! unless its UNION bit is set.
//!
//! That is the whole of what a line or a triangle is on this engine: four
//! perpendicular limiters for a stroke (ra8_drw_draw.c
//! `internal_program_line_limiters`, HUM Ch 62.4.4 p 3725), three edges for a
//! triangle. dev declined every one of them, so a firmware that drew anything
//! but an axis-aligned rectangle came back to a blank framebuffer.
//!
//! Two parts of the block are deliberately left out rather than guessed at,
//! because inventing pixels is the divergence this tree exists to prevent:
//!
//!   * QUAD1/2/3, the quadratic coupling that turns a limiter pair into a
//!     curve. It is a different evaluation, not a harder one, and no in-tree
//!     primitive programs it. drw.zig declines a render that enables one.
//!   * The anti-aliased edge. With LIMnTHRESHOLD clear the engine spreads
//!     coverage across the sub-pixel band at the boundary; the bench sweeps
//!     recorded in board_periph_drw.c on dev saw that coverage arrive as
//!     alpha 0x01-0x02 rather than a clean ramp, which no linear reading of
//!     HUM Ch 62.6.2.1 predicts. So the test here is the hard one either way,
//!     and every pixel that lands inside the boundary band is counted, so a
//!     run says how much of its picture sits where the two would differ.
const std = @import("std");

/// Register byte offsets, each the first of a run of six (ra8_drw_regs.h).
pub const off = struct {
    pub const start: u32 = 0x010;
    pub const xadd: u32 = 0x028;
    pub const yadd: u32 = 0x040;
    pub const band1: u32 = 0x058;
    pub const band2: u32 = 0x05C;
    pub const stride: u32 = 4;
};

/// CONTROL, the geometry control register (HUM Ch 62.2.1 p 3689).
pub const control = struct {
    pub const enables: u32 = 0x3F;
    pub const quads: u32 = 0x7 << 6;
    pub const thresholds: u32 = 0x3F << 9;
    pub const band1: u32 = 1 << 15;
    pub const band2: u32 = 1 << 16;
    pub const union12: u32 = 1 << 17;
    pub const union34: u32 = 1 << 18;
    pub const union56: u32 = 1 << 19;
    pub const union_ab: u32 = 1 << 20;
    pub const union_cd: u32 = 1 << 21;
};

/// One pixel is sixteen sub-pixels (ra8_drw_regs.h `ra8_drw_subpixel_t`).
pub const subpixel = struct {
    pub const shift: u5 = 4;
    pub const unit: i64 = 1 << shift;
};

pub const count: usize = 6;

/// One edge: the linear form and the band width that may narrow it.
pub const Limiter = struct {
    start: i32 = 0,
    xadd: i32 = 0,
    yadd: i32 = 0,
    /// L1BAND / L2BAND, in sub-pixels. Only limiters 1 and 2 have one.
    band: u32 = 0,

    /// The limiter's value at a pixel, in sub-pixels.
    pub fn value(self: Limiter, x: u32, y: u32) i64 {
        return @as(i64, self.start) +
            @as(i64, self.xadd) * @as(i64, x) +
            @as(i64, self.yadd) * @as(i64, y);
    }

    /// Whether the pixel is admitted. A band turns the half-plane into a
    /// slab of that width, which is how a stroke gets its thickness.
    pub fn admits(self: Limiter, x: u32, y: u32, banded: bool) bool {
        const at = self.value(x, y);
        if (at < 0) return false;
        if (banded and self.band != 0 and at >= @as(i64, self.band)) return false;
        return true;
    }

    /// Whether the pixel sits within one sub-pixel of the boundary, where an
    /// anti-aliased engine would paint partial coverage and this one does
    /// not.
    pub fn onEdge(self: Limiter, x: u32, y: u32) bool {
        const at = self.value(x, y);
        return at >= -subpixel.unit and at < subpixel.unit;
    }
};

/// The six limiters and the tree CONTROL folds them down.
pub const Set = struct {
    edges: [count]Limiter = @splat(Limiter{}),

    /// Take a register write. Returns false when the offset is not one of
    /// this set's, so the caller can keep its own switch small.
    pub fn latch(self: *Set, offset: u32, value: u32) bool {
        const signed: i32 = @bitCast(value);
        if (index(offset, off.start)) |n| {
            self.edges[n].start = signed;
            return true;
        }
        if (index(offset, off.xadd)) |n| {
            self.edges[n].xadd = signed;
            return true;
        }
        if (index(offset, off.yadd)) |n| {
            self.edges[n].yadd = signed;
            return true;
        }
        switch (offset) {
            off.band1 => self.edges[0].band = value,
            off.band2 => self.edges[1].band = value,
            else => return false,
        }
        return true;
    }

    /// What this set holds for a register, so a narrow store keeps the lanes
    /// it does not name. Null when the offset is not one of this set's, the
    /// same seam `latch` answers on.
    pub fn held(self: *const Set, offset: u32) ?u32 {
        if (index(offset, off.start)) |n| return @bitCast(self.edges[n].start);
        if (index(offset, off.xadd)) |n| return @bitCast(self.edges[n].xadd);
        if (index(offset, off.yadd)) |n| return @bitCast(self.edges[n].yadd);
        return switch (offset) {
            off.band1 => self.edges[0].band,
            off.band2 => self.edges[1].band,
            else => null,
        };
    }

    /// Whether the configuration limits anything at all. A render with no
    /// enable set is the plain bounding box, the case dev always handled.
    pub fn active(ctl: u32) bool {
        return ctl & control.enables != 0;
    }

    /// The final coverage answer for one pixel.
    pub fn admits(self: *const Set, ctl: u32, x: u32, y: u32) bool {
        const a = self.pair(ctl, 0, ctl & control.union12 != 0, x, y);
        const b = self.pair(ctl, 2, ctl & control.union34 != 0, x, y);
        const d = self.pair(ctl, 4, ctl & control.union56 != 0, x, y);
        const c = combine(a, b, ctl & control.union_ab != 0);
        return combine(c, d, ctl & control.union_cd != 0) orelse true;
    }

    /// Whether any enabled limiter puts this pixel on its boundary band.
    pub fn onEdge(self: *const Set, ctl: u32, x: u32, y: u32) bool {
        for (self.edges, 0..) |edge, n| {
            if (ctl & (@as(u32, 1) << @intCast(n)) == 0) continue;
            if (edge.onEdge(x, y)) return true;
        }
        return false;
    }

    /// One rung of the tree: two neighbouring limiters, or whichever of them
    /// is enabled, or no opinion when neither is.
    fn pair(self: *const Set, ctl: u32, first: usize, unite: bool, x: u32, y: u32) ?bool {
        return combine(
            self.one(ctl, first, x, y),
            self.one(ctl, first + 1, x, y),
            unite,
        );
    }

    fn one(self: *const Set, ctl: u32, n: usize, x: u32, y: u32) ?bool {
        if (ctl & (@as(u32, 1) << @intCast(n)) == 0) return null;
        const banded = switch (n) {
            0 => ctl & control.band1 != 0,
            1 => ctl & control.band2 != 0,
            else => false,
        };
        return self.edges[n].admits(x, y, banded);
    }
};

/// A disabled side contributes nothing, so it passes the other side through
/// unchanged rather than forcing the pair one way.
fn combine(left: ?bool, right: ?bool, unite: bool) ?bool {
    const l = left orelse return right;
    const r = right orelse return l;
    return if (unite) l or r else l and r;
}

fn index(offset: u32, base: u32) ?usize {
    if (offset < base or offset >= base + off.stride * count) return null;
    if ((offset - base) % off.stride != 0) return null;
    return (offset - base) / off.stride;
}
