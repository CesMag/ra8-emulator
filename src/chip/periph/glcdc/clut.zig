//! The GLCDC's colour lookup tables: where a CLUT-mode pixel's colour
//! actually comes from.
//!
//! The window opens with four 1 KiB CLUT planes (ra8_glcdc_regs.h, HUM Ch 63
//! p 3730), two per graphics layer, 256 ARGB8888 entries each:
//!
//!   0x0000  GR1_CLUT0[256]
//!   0x0400  GR1_CLUT1[256]
//!   0x0800  GR2_CLUT0[256]
//!   0x0C00  GR2_CLUT1[256]
//!
//! A layer has two planes so a driver can fill the one it is not showing and
//! swap at a line boundary; GRn_CLUTINT.SEL picks which plane the fetch unit
//! reads. dev models none of this: its snoop takes eleven offsets and the
//! CLUT planes are not among them, so every CLUT entry a driver wrote fell
//! into the sparse register file and the index bytes in the framebuffer were
//! hashed as if they were colours.
const std = @import("std");

/// Where the planes are and how big they are.
pub const geometry = struct {
    /// Entries in one plane. The index byte is eight bits wide, so this is
    /// the whole addressable palette.
    pub const entries: u32 = 256;
    /// Bytes in one plane: 256 ARGB8888 words.
    pub const plane_bytes: u32 = entries * 4;
    /// Planes per layer.
    pub const planes: u32 = 2;
    /// Where layer 1's first plane starts. Layer 2's pair follows layer 1's.
    pub const base: u32 = 0x0000;
    /// Bytes one layer's pair of planes occupies.
    pub const layer_bytes: u32 = plane_bytes * planes;
    /// One past the last CLUT byte, where the BG block's own registers begin.
    pub const end: u32 = base + layer_bytes * 2;
};

/// GRn_CLUTINT fields (HUM Ch 63 p 3752).
pub const clutint = struct {
    /// SEL, bit 16: which plane the fetch unit reads from.
    pub const sel: u32 = 1 << 16;
};

/// Which plane of which layer an offset inside the CLUT area names.
pub const Slot = struct { layer: u8, plane: u8, index: u32 };

/// Decompose a window offset into the plane and entry it addresses, or null
/// when the offset is past the CLUT area.
pub fn slotOf(offset: u32) ?Slot {
    if (offset >= geometry.end) return null;
    const plane_number = offset / geometry.plane_bytes;
    return .{
        .layer = @intCast(plane_number / geometry.planes + 1),
        .plane = @intCast(plane_number % geometry.planes),
        .index = offset % geometry.plane_bytes / 4,
    };
}

/// One layer's pair of palettes, and what the layer has actually filled.
///
/// An entry is not just a colour: it is a colour a driver either wrote or
/// did not. A plane nobody filled is a plane of zeroes, which on silicon
/// scans out as transparent black; reporting that as a palette would hide
/// exactly the mistake worth catching, so the filled count is kept and the
/// scan asks about it before it trusts a lookup.
pub const Palette = struct {
    planes: [geometry.planes][geometry.entries]u32 = @splat(@splat(0)),
    /// Entries written per plane, so an unprogrammed palette is knowable.
    filled: [geometry.planes]u32 = @splat(0),
    /// Which plane the fetch unit reads, from CLUTINT.SEL.
    selected: u8 = 0,

    /// Take one CLUT word. A second write to the same entry is not a second
    /// fill: the count is entries touched, not writes taken.
    pub fn store(self: *Palette, plane: u8, index: u32, value: u32) void {
        if (plane >= geometry.planes or index >= geometry.entries) return;
        if (self.planes[plane][index] == 0 and value != 0) self.filled[plane] += 1;
        self.planes[plane][index] = value;
    }

    pub fn load(self: *const Palette, plane: u8, index: u32) u32 {
        if (plane >= geometry.planes or index >= geometry.entries) return 0;
        return self.planes[plane][index];
    }

    /// CLUTINT.SEL: the plane the fetch unit reads from here on.
    pub fn select(self: *Palette, value: u32) void {
        self.selected = if (value & clutint.sel != 0) 1 else 0;
    }

    /// Whether the selected plane has anything in it. A CLUT-mode layer over
    /// an empty plane is a black panel, and that is worth refusing rather
    /// than hashing 256 zeroes into a plausible-looking witness.
    pub fn programmed(self: *const Palette) bool {
        return self.filled[self.selected] != 0;
    }

    /// The colour an index scans out as, through the selected plane.
    pub fn colour(self: *const Palette, index: u32) u32 {
        return self.load(self.selected, index);
    }

    pub fn quiet(self: *const Palette) bool {
        return self.filled[0] == 0 and self.filled[1] == 0;
    }
};
