//! The DRW texture CLUT: the palette an indexed texture is read through.
//!
//! An indexed READFORMAT (CLUT1/2/4/8, ACLUT44) does not carry colour, it
//! carries an index into this table, so a textured blit through one of them
//! stores whatever the driver loaded here. The table is 256 entries on the
//! RA8D2 (ra8_drw_regs.h `k_ra8_drw_hwrev_texclut256`), loaded a word at a
//! time: TEXCLADDR sets the cursor, each TEXCLDATA write stores one entry
//! and steps it on, and TEXCLOFFSET shifts every later lookup.
//!
//! The entry format is CONTROL2.CLUTFORMAT's call, not the texture's: set,
//! entries are RGB565 and the alpha byte is opaque; clear, entries are
//! ARGB8888 exactly as written.
const std = @import("std");

/// Table geometry (HUM Ch 62.2.29-62.2.31 pp 3704-3705).
pub const size = struct {
    pub const entries: u32 = 256;
    pub const index_mask: u32 = 0xFF;
    pub const address_mask: u32 = 0xFF;
    pub const offset_mask: u32 = 0xFF;
};

/// RGB565 entry unpacking, for when CONTROL2.CLUTFORMAT is set.
pub const rgb565 = struct {
    pub const red_shift: u5 = 11;
    pub const green_shift: u5 = 5;
    pub const red_bits: u32 = 0x1F;
    pub const green_bits: u32 = 0x3F;
    pub const blue_bits: u32 = 0x1F;
    pub const opaque_alpha: u32 = 0xFF00_0000;
};

/// The palette and its load cursor.
pub const Clut = struct {
    entries: [size.entries]u32 = @splat(0),
    cursor: u32 = 0,
    offset: u32 = 0,
    /// Entries loaded, so a run can say whether a palette was ever written.
    loaded: u32 = 0,

    pub fn setAddress(self: *Clut, value: u32) void {
        self.cursor = value & size.address_mask;
    }

    /// One TEXCLDATA write: store at the cursor and step it, wrapping at the
    /// end of the table the way the load counter does on silicon.
    pub fn push(self: *Clut, value: u32) void {
        self.entries[self.cursor] = value;
        self.cursor = (self.cursor + 1) & size.address_mask;
        self.loaded +%= 1;
    }

    pub fn setOffset(self: *Clut, value: u32) void {
        self.offset = value & size.offset_mask;
    }

    /// The ARGB8888 colour an index names, with TEXCLOFFSET applied and the
    /// sum wrapped into the table.
    pub fn lookup(self: *const Clut, index: u32, packed_565: bool) u32 {
        const at = (index + self.offset) & size.index_mask;
        const entry = self.entries[at];
        if (!packed_565) return entry;
        return expand565(entry);
    }

    pub fn quiet(self: *const Clut) bool {
        return self.loaded == 0;
    }
};

/// An RGB565 entry as ARGB8888, each channel scaled so full bits give 0xFF
/// rather than a value short of it.
pub fn expand565(entry: u32) u32 {
    const r = entry >> rgb565.red_shift & rgb565.red_bits;
    const g = entry >> rgb565.green_shift & rgb565.green_bits;
    const b = entry & rgb565.blue_bits;
    return rgb565.opaque_alpha |
        scale(r, rgb565.red_bits) << 16 |
        scale(g, rgb565.green_bits) << 8 |
        scale(b, rgb565.blue_bits);
}

/// Widen an n-bit channel to eight bits: value * 255 / full, rounded.
pub fn scale(value: u32, full: u32) u32 {
    return @min((value * 255 + full / 2) / full, 0xFF);
}

comptime {
    std.debug.assert(size.entries == size.index_mask + 1);
}
