//! The IWDT's view of OFS0: whether the boot ROM starts the counter at all.
//!
//! On the RA8D2 the IWDT has no register-start mode. The option word at
//! OFS0 decides at reset whether the counter runs, and IWDTSTRT (bit 1) set
//! is the stopped selection (ra8_iwdt_regs.h, ra8_iwdt_ofs0_layout_t). A
//! blank part reads 0xFFFFFFFF there, so an image that leaves
//! BSP_CFG_OPTION_SETTING_OFS0 at its in-tree erased default
//! (libs/ra8_hal/src/ra8_ofs.c) gets an IWDT that never counts, however
//! often it refreshes. Only the start bit is read here; the period, window
//! and NMI-versus-reset fields stay unmodelled, the same as in iwdt.zig.

/// Where the word sits in MRAM (ra8_ofs.h, k_ra8_ofs0_addr).
pub const address: u32 = 0x02C9_F040;

/// What a part that was never programmed reads back.
pub const erased: u32 = 0xFFFF_FFFF;

pub const field = struct {
    /// IWDTSTRT: 0 = auto-start at reset, 1 = stopped.
    pub const strt: u32 = 0x0000_0002;
};

/// Whether this option word starts the IWDT at reset.
pub fn autoStarts(word: u32) bool {
    return word & field.strt == 0;
}
