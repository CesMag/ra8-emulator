//! The RTC frequency registers, RFRH and RFRL, and the two ordering rules
//! the driver's own clock bring-up depends on.
//!
//! RFRH sits at +0x2A and RFRL at +0x2C in the RTC window
//! (ra8_rtc_regs.h). Together they carry RFC, the count the prescaler
//! divides the count source by: RFRH holds bit 16 and RFRL the low
//! sixteen, so for a 32.768 kHz LOCO the driver writes RFRH = 0 and
//! RFRL = 0x00FF, which is (LOCO / 128) - 1.
//!
//! The whole pair was a plain shadow here: a store landed, a load read it
//! back, and nothing else. Neither rule the driver follows was checked, so
//! a run could not tell a correct bring-up from one that skipped both.
//!
//! RULE ONE, THE PRESCALER MUST BE STOPPED. ra8_rtc.c lines 282-286 clear
//! RCR2.START and wait for the bit to fall before touching the pair, and
//! says why in its own comment: "HUM Ch 26.2.21 RCR2 p 1232 -- stop the
//! prescaler (START = 0) before the frequency register and software
//! reset". The same file already refuses a calendar counter write with the
//! count running, which is the neighbouring rule with a stated outcome.
//! This one has no stated outcome, so a hot store is COUNTED AND STILL
//! LANDS rather than being refused: the manual page in this tree names the
//! precondition and does not say what the part does to a driver that
//! ignores it, and inventing a refusal would put words in its mouth.
//!
//! RULE TWO, RFRH GOES FIRST ON A COLD START. ra8_rtc.c lines 288-294 write
//! RFRH before RFRL and cites "HUM Ch 26.2.25 RFRH p 1237 -- clear RFRH
//! before RFRL on a cold start". Counted the one way this model can see it:
//! an RFRL store with RFRH untouched since the last reset. A driver that
//! sets the low half of the divisor while the high bit still holds whatever
//! the cold start left there is running the prescaler on a count nobody
//! wrote whole.
//!
//! NOT MODELLED, AND NOT GUESSED: what RFC actually does to the rate. This
//! model counts a second of its own rather than dividing a real 32.768 kHz
//! source, so the divisor is recorded and reported, never applied. RADJ and
//! RADJ2 above the pair are clock trimming against a real crystal and stay
//! the shadow they were.

/// Where the pair sits in the RTC window (ra8_rtc_regs.h).
pub const off = struct {
    pub const rfrh: u32 = 0x2A;
    pub const rfrl: u32 = 0x2C;
};

/// Both registers are 16 bits wide.
pub const reg_bytes: u32 = 2;

/// Whether an offset lands anywhere in the frequency pair.
pub fn names(offset: u32) bool {
    return offset >= off.rfrh and offset < off.rfrl + reg_bytes;
}

/// Whether an offset lands in RFRH rather than RFRL.
pub fn namesHigh(offset: u32) bool {
    return offset >= off.rfrh and offset < off.rfrh + reg_bytes;
}

/// The two rules, and what the run saw of them.
pub const Frequency = struct {
    /// Stores taken while RCR2.START still had the prescaler running.
    hot_stores: u32 = 0,

    /// RFRL stores taken with RFRH untouched since the last reset.
    out_of_order: u32 = 0,

    /// Whether RFRH has been written since the last reset.
    high_written: bool = false,

    /// One byte of a store into the pair. The byte still lands in the RTC
    /// shadow; this only judges it.
    pub fn note(self: *Frequency, offset: u32, running: bool) void {
        if (running) self.hot_stores +%= 1;
        if (namesHigh(offset)) {
            self.high_written = true;
            return;
        }
        if (!self.high_written) self.out_of_order +%= 1;
    }

    /// A software reset puts the pair back to its cold-start footing, so the
    /// order rule applies again to whatever the driver writes next.
    pub fn clear(self: *Frequency) void {
        self.high_written = false;
    }

    /// Nothing worth a line in the report.
    pub fn quiet(self: *const Frequency) bool {
        return self.hot_stores == 0 and self.out_of_order == 0;
    }
};
