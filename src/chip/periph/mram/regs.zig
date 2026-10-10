//! Where the extra-MRAM controller's registers sit and what their bits mean.
//! Split out of src/chip/periph/mram/mram.zig so the block file holds the rules and
//! this one holds the numbers, the way eth/regs.zig sits beside eth.zig.
//! Offsets are ra8_flash_regs.h's, relative to the MRMS program-mode
//! sub-window rather than to the MRAM base the header counts from: the
//! header's k_ra8_mram_off_msaddr = 0x2030 is this file's 0x30.

/// The MRMS program-mode sub-window (ra8_flash_regs.h). Deliberately narrow:
/// it covers only the program-mode registers, not the configuration page
/// below it.
pub const regs = struct {
    pub const base: u32 = 0x4013_E000;
    pub const span: u32 = 0x100;
    pub const off_mastat: u32 = 0x10;
    pub const off_msaddr: u32 = 0x30;
    pub const off_mstatr: u32 = 0x80;
    pub const off_mentryr: u32 = 0x84;
    /// MENTRYR is sixteen bits wide, so only the low half of the word it
    /// sits in is the register; the two bytes above it are not.
    pub const mentryr_bytes: u32 = 2;
};

/// The MACI command-issuing area: one port, byte and halfword wide.
pub const command = struct {
    pub const base: u32 = 0x4012_0000;
    pub const span: u32 = 0x10;
};

pub const field = struct {
    /// MENTRYR.MENTRY, the program/erase mode status bit.
    pub const mentry: u32 = 0x0080;
    /// MENTRYR.PCKA, the pause gate: set by the keyed pause pattern, clear
    /// again on the keyed resume, and readable either way.
    pub const pcka: u32 = 0x0040;
    /// The key byte MENTRYR takes in its high half.
    pub const key: u32 = 0xAA00;
    pub const key_mask: u32 = 0xFF00;
    /// MSTATR.MRDY, command complete.
    pub const mrdy: u32 = 0x0000_8000;
    /// MSTATR.ILGLERR, illegal.
    pub const ilglerr: u32 = 0x0000_4000;
    /// MSTATR.ILGCOMERR, illegal command.
    pub const ilgcomerr: u32 = 0x0080_0000;
    /// MASTAT.MREAE, extra-MRAM access error.
    pub const mreae: u32 = 0x08;
    /// MASTAT.CMDLK, the command-locked state.
    pub const cmdlk: u32 = 0x10;
};
