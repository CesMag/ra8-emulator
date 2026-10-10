//! The SSIE software reset: SSIFCR.SSIRST, a command rather than a stored bit.
//!
//! SSIFCR sits at +0x10 in a channel's window and is mostly settings: the two
//! FIFO resets at bits 0 and 1, the receive and transmit interrupt enables,
//! the two trigger fields, BSW, and AUCKE at the top (ra8_ssie_regs.h
//! `ra8_ssifcr_mask_t`, HUM Ch 46.2.3 p 3077). Bit 16 is not a setting. It is
//! the module's own software reset, the one HUM Table 46.9 is named after
//! ("Bits subject to software reset by the SSIRST bit", p 3081), and the
//! driver drives it three times over: at bring-up through
//! internal_pulse_ssi_reset, and on every error recovery through
//! ra8_ssie_start_recovery (ra8_ssie.c lines 545 and 727-732).
//!
//! WHAT THE RESET DOES IS NOT GUESSED HERE. HUM Table 46.9 itself is not in
//! this tree, but ra8_ssie.h states the post-conditions of the recovery call
//! that does nothing else, and those are the contract this file keeps
//! (inc/ra8_ssie.h lines 444-446):
//!
//!     @post FIFOs are empty and all SSISR error flags cleared.
//!     @post SSICR retains its mode bits (only TEN/REN are touched).
//!
//! ra8_ssie_start_recovery pulses SSIRST, waits, and then clears the SSISR
//! error flags by hand; it never writes SSICR at all. So the enables going
//! down is the RESET's doing, not the caller's, and a channel that has been
//! reset comes back idle.
//!
//! THE BIT IS HELD, NOT SELF-CLEARING, and that is deliberate. The prose in
//! ra8_ssie.h says "waits for it to self-clear", but both drive sites write
//! the bit high and then low themselves before they poll, exactly like
//! mipi/dsi.zig's RSTCR.SWRST and unlike rtc/reset.zig's RCR2.RESET, which
//! the driver writes once and then polls down. Nothing in either tree says
//! the hardware would clear this one, so it stays in the shadow and reads
//! back what firmware wrote: the reset happens on the edge that asserts it,
//! the same rule fifo.zig already keeps for RFRST and TFRST.
//!
//! NOT MODELLED, AND NOT GUESSED: the rest of Table 46.9. SSIOFR, SSISCR and
//! the trigger fields are shadow in this model and are left where they were;
//! widening the reset to them would need the table, and inventing the list
//! would silently wipe a configuration firmware had just written. SSISR's
//! error flags are nothing to clear here either, because this model computes
//! SSISR on read from SSICR rather than latching flags into it.

/// SSIFCR.SSIRST (ra8_ssie_regs.h `k_ra8_ssie_mask_ssirst`).
pub const mask = struct {
    pub const ssirst: u32 = 0x0001_0000;
};

/// SSICR bits the reset takes down. The mode bits above these ride through.
pub const clears = struct {
    /// SSICR.REN | SSICR.TEN, the pair ra8_ssie.h says the reset touches.
    pub const enables: u32 = 0x0000_0003;
};

/// Whether this store asks for the reset, given what SSIFCR held before.
/// Only a rising edge resets, so a driver leaving the bit set and then
/// writing another SSIFCR field does not reset the channel a second time.
pub fn asserted(before: u32, after: u32) bool {
    return after & ~before & mask.ssirst != 0;
}

/// What SSICR keeps across the reset: everything but the two enables.
pub fn control(ssicr: u32) u32 {
    return ssicr & ~clears.enables;
}
