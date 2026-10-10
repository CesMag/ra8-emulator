//! DAC_B output gating and data placement: whether a code written to a
//! channel converts at all, and which twelve bits of DADR carry it.
//!
//! dac.zig read one bit of this block, DACR0.DACEN, and took every code as
//! right-justified in the low twelve bits of DADR. Both are half a rule. Its
//! own note said no header for the part was in this tree; ra8-firmware's
//! ra8_dac_b_regs.h on zig/dev is one. DACR0 carries DACEN at bit 0, DAE at
//! bit 15 and DAOUTDIS at bit 31 (mirrors of FSP `R_DAC_B0_DACR0_*_Msk`, HUM
//! Ch 54), and DACR1 carries DPSEL at bit 16.
//!
//! DAOUTDIS HAS A LIVE DRIVER. ra8_dac_b.c's `internal_apply_cfg` sets it on
//! every channel opened with `internal_output_enabled` false, and
//! `ra8_dac_b_deinit` writes DACR0 = DAOUTDIS to both channels outright, so
//! the block's shut-down state is DACEN clear and DAOUTDIS set. A channel
//! with its output disabled converts nothing whatever its enable reads, so a
//! code stored there is staged, not driven, and counting it as an output is
//! the same lie the DACEN count was added to catch.
//!
//! DPSEL HAS ONE TOO. The same function writes DACR1 = data_format << DPSEL,
//! and ra8_dac_b.h names the two encodings: 0 right-justified, 1
//! left-justified twelve bits in the sixteen-bit DADR field. Taking the low
//! twelve regardless turns a left-justified driver's full scale into fifteen
//! counts, and its readback into a value silicon never held.
//!
//! NOT MODELLED, AND NOT GUESSED: DAE, bit 15. The header names it "batch
//! conversion control" and nothing in either tree writes it or says what a
//! batch does, so it rides in the register and is never read. DACR2.OFSSEL
//! picks the VREFH range, which is a voltage a headless run cannot show.

/// The control register this file adds to the two dac.zig already names.
pub const off = struct {
    pub const dacr1: u32 = 0x08;
};

/// The bits ra8_dac_b_regs.h names (FSP `R_DAC_B0_DACR*_*_Msk`).
pub const mask = struct {
    pub const dacen: u32 = 0x0000_0001;
    pub const dae: u32 = 0x0000_8000;
    pub const daoutdis: u32 = 0x8000_0000;
    pub const dpsel: u32 = 0x0001_0000;
};

/// Where the twelve bits sit inside the sixteen-bit DADR field.
pub const Placement = enum {
    right,
    left,

    pub fn of(dacr1: u32) Placement {
        return if (dacr1 & mask.dpsel != 0) .left else .right;
    }

    /// The bits of DADR silicon has in this placement. The other four are
    /// not there, so they do not read back.
    pub fn held(self: Placement) u16 {
        return switch (self) {
            .right => 0x0FFF,
            .left => 0xFFF0,
        };
    }

    /// The code a DADR field carries.
    pub fn code(self: Placement, dadr: u16) u16 {
        return switch (self) {
            .right => dadr & self.held(),
            .left => dadr >> 4,
        };
    }

    pub fn name(self: Placement) []const u8 {
        return switch (self) {
            .right => "right-justified",
            .left => "left-justified",
        };
    }
};

/// A channel converts only when it is enabled and its output is not disabled.
pub fn driving(dacr0: u32) bool {
    return dacr0 & mask.dacen != 0 and dacr0 & mask.daoutdis == 0;
}
