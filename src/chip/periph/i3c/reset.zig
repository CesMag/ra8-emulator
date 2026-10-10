//! RSTCTL: the I3C channel's reset requests, which are commands that
//! auto-clear rather than bits that sit in a register.
//!
//! RSTCTL is at +0x020 (ra8_i3c_regs.h `k_ra8_i3c_off_rstctl`, HUM Ch 40.2.4
//! p 2451). Bit 0 is RI3CRST, the block's own software reset; bits 1 to 6
//! are the per-queue resets; bit 16 is INTLRST, which flushes the internal
//! state machines. Both drivers in the tree pulse them before touching
//! anything else, and both say in so many words that the hardware takes the
//! bit back down again.
//!
//! ra8_i3c.c's bring-up sequence (lines 120-124, 139-150):
//!
//!     3. Pulse RSTCTL.RI3CRST -- on real silicon the bit auto-clears
//!        when the I3C internal reset completes; here we issue an
//!        explicit clear so the fake-mmap unit-test back-end does
//!        not spin forever
//!
//! and ra8_i3c_i2c.c's (lines 245-260) writes the bit, writes zero, then
//! spins up to k_ra8_i3c_i2c_poll_limit = 200000 times waiting to read it
//! clear, with `k_ra8_err_hw_timeout RSTCTL.RI3CRST didn't self-clear` as the
//! documented failure (ra8_i3c_i2c.h line 118).
//!
//! SELF-CLEARING, unlike ssie/reset.zig's SSIFCR.SSIRST. That one is held
//! because both of its drive sites write it high and then low themselves
//! before polling, and nothing in either tree says the hardware would clear
//! it. This one is the opposite case: both drive sites say the hardware
//! clears it, and one of them returns a timeout error when it does not. So
//! the bits are spent on the write and RSTCTL reads back zero.
//!
//! WHAT THE RESET DOES is the transfer machine, and no more. A channel that
//! has been reset is idle: no transaction open, nothing addressed, nothing
//! staged, the buffer empty and ready for the first address byte, and the
//! condition flags from whatever went before cleared. That is what makes the
//! sequence worth issuing at bring-up, and it is what both drivers rely on:
//! ra8_i3c_i2c_init resets FIRST, then applies its configuration registers,
//! so a reset that also wiped configuration would wipe nothing it had
//! written yet.
//!
//! NOT MODELLED, AND NOT GUESSED: which configuration registers HUM Ch 40's
//! RSTCTL description restores, and what each per-queue bit resets on its
//! own. That table is not in this tree. The per-queue bits are therefore
//! counted and spent but reset nothing here beyond what RI3CRST already
//! does, and the configuration shadow rides through untouched: inventing the
//! list would silently wipe registers firmware had just written, which is
//! the worse direction to be wrong in. INTLRST takes the transfer machine
//! down the same way RI3CRST does, which is the one thing ra8_i3c.c's
//! comment does state about it ("flush the internal state machines"). The
//! responder half rides through on the same grounds: what arms it is the own
//! address in MSDVAD, which is configuration, and writing MSDVAD zero is how
//! firmware gives that role back up.

/// RSTCTL's offset in the channel window (ra8_i3c_regs.h).
pub const off: u32 = 0x020;

/// RSTCTL's bits (ra8_i3c_regs.h `ra8_i3c_rstctl_bits_t`).
pub const mask = struct {
    /// RI3CRST: the block's own software reset.
    pub const ri3crst: u32 = 0x0000_0001;
    pub const cmdqrst: u32 = 0x0000_0002;
    pub const rspqrst: u32 = 0x0000_0004;
    pub const tdbrst: u32 = 0x0000_0008;
    pub const rdbrst: u32 = 0x0000_0010;
    pub const ibiqrst: u32 = 0x0000_0020;
    pub const rsqrst: u32 = 0x0000_0040;
    /// INTLRST: flushes the internal state machines.
    pub const intlrst: u32 = 0x0001_0000;
    /// The six per-queue resets as one.
    pub const queues: u32 = cmdqrst | rspqrst | tdbrst | rdbrst | ibiqrst | rsqrst;
    /// Every bit this register defines.
    pub const any: u32 = ri3crst | queues | intlrst;
};

/// Whether this store asks for the channel to go back to idle. The two
/// whole-block resets do; a per-queue bit on its own does not, because what
/// each of those resets is not in this tree to read.
pub fn resetsChannel(value: u32) bool {
    return value & (mask.ri3crst | mask.intlrst) != 0;
}

/// Whether this store asks for anything at all.
pub fn requested(value: u32) bool {
    return value & mask.any != 0;
}

/// What the store leaves behind. Every defined bit is a command and is
/// spent, so RSTCTL reads back with none of them standing; an undefined bit
/// is not this file's to swallow and lands in the shadow as before.
pub fn stored(value: u32) u32 {
    return value & ~mask.any;
}
