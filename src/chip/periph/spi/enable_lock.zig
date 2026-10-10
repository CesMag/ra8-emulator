//! Registers the SPI_B channel locks once SPE is set.
//!
//! SPCR2 carries the two loopback ties and the COPI idle-value pair, and the
//! hardware only honors a store to it while SPCR.SPE is clear. Both drivers
//! in the firmware tree say so in the same words and cite the same page:
//! `internal_spi_program_regs` in ra8_spi_b.c ("SPCR2 only honors writes
//! while SPE=0", HUM Ch 43.2.4 "SPCR2 : SPI Control Register 2" p 2889) and
//! `internal_target_program_regs` in ra8_spi_b_target.c ("No loopback in
//! target mode. SPCR2 must be written while SPE=0", same citation). Both
//! reach it from a path whose precondition is `reg->SPCR == 0`.
//!
//! A model that takes the store anyway cannot tell the two orders apart. A
//! driver that enables the channel and then asks for the internal tie gets a
//! tie here and bare pins on the bench, so a headless run reports frames
//! echoing back that the board would read as zero; a teardown that clears
//! SPCR2 before it clears SPE drops the tie here and leaves it standing
//! there. Neither shows up as an error either way, which is what makes it
//! worth a rule rather than a comment.

/// SPCR2 while the channel is running: the store lands on nothing.
pub const Locked = struct {
    /// Stores refused because SPE was set.
    ignored: u32 = 0,

    /// Whether a store made now reaches the register. `running` is
    /// SPCR.SPE as it stands BEFORE this access, which is the state the
    /// hardware latches against: a store to SPCR2 and a store to SPCR are
    /// different accesses, so enabling the channel never locks itself out.
    pub fn takes(self: *Locked, running: bool) bool {
        if (running) {
            self.ignored +%= 1;
            return false;
        }
        return true;
    }

    pub fn quiet(self: *const Locked) bool {
        return self.ignored == 0;
    }
};
