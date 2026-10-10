//! ACMPHS output monitor: what CMPMON answers, and when it answers nothing.
//!
//! CMPMON is the only window a headless run has onto a comparator. It is a
//! read-only register (ra8_acmphs_regs.h, "+0x0C CMPMON 8 Output monitor
//! (read-only)"), so firmware cannot store a level and read its own invention
//! back out of it, and `ra8_acmphs_read_output` in ra8_acmphs.c reads it and
//! masks it with CMPMON bit 0 to decide `k_ra8_level_high` or `_low`.
//!
//! THE COMPARISON ITSELF IS NOT MODELLED, AND NOT GUESSED. CMPSEL0 and
//! CMPSEL1 select a plus input and a minus reference by index, not by
//! voltage, and there is no analog rail in this emulator for either of them
//! to sit on. So the comparator's own verdict stays at its reset result,
//! plus below reference, output low, and this file models the two things
//! around it that firmware can actually drive: whether the comparator is
//! operating at all, and the polarity it presents its result through.
//!
//!   HCMPON (bit 7) clear  ->  the comparator is off and monitors nothing,
//!                             so CMPMON reads 0 whatever CINV says.
//!   CINV   (bit 0) set    ->  the output is inverted on the way out, so the
//!                             low verdict presents as high.
//!
//! Both bits are from ra8_acmphs_regs.h's own mask table (k_ra8_acmphs_mask_
//! hcen 0x80 "HCMPON operation enable", k_ra8_acmphs_mask_cinv 0x01 "Output
//! polarity inversion"), which cites FSP R_ACMPHS0_CMPCTL_b.
//!
//! NOT MODELLED, AND NOT GUESSED: CEG[1:0] at [4:3], the edge selector, and
//! CDFS[1:0] at [6:5], the noise-filter sampling clock. An edge needs a
//! verdict that changes and a filter needs a sampling clock, and this model
//! has neither. COE (bit 1) drives the result onto a pin a headless run has
//! nothing to show on. All three ride in CMPCTL and read back.

/// CMPCTL field masks (ra8_acmphs_regs.h, ra8_acmphs_mask_t).
pub const mask = struct {
    pub const cinv: u8 = 0x01;
    pub const coe: u8 = 0x02;
    pub const csten: u8 = 0x04;
    pub const ceg: u8 = 0x18;
    pub const cdfs: u8 = 0x60;
    pub const hcmpon: u8 = 0x80;
};

/// CMPMON's one meaningful bit (k_ra8_acmphs_mask_hcmon).
pub const cmpmon: u8 = 0x01;

/// CMPCTL.CEG[1:0], the edge a configured channel asks to be told about.
/// Named so a report can say what was asked for; nothing here acts on it.
pub const Edge = enum(u2) {
    none = 0,
    rising = 1,
    falling = 2,
    both = 3,

    pub fn of(cmpctl: u8) Edge {
        return @fromBackingInt(@intCast(@as(u2, @truncate((cmpctl & mask.ceg) >> 3))));
    }

    pub fn name(self: Edge) []const u8 {
        return switch (self) {
            .none => "no edge",
            .rising => "rising edge",
            .falling => "falling edge",
            .both => "either edge",
        };
    }
};

/// Is the comparator operating? Nothing is monitored while HCMPON is clear.
pub fn operating(cmpctl: u8) bool {
    return cmpctl & mask.hcmpon != 0;
}

/// Is the result inverted on the way to CMPMON and the pin?
pub fn inverted(cmpctl: u8) bool {
    return cmpctl & mask.cinv != 0;
}

/// Is the result driven onto the output pin as well?
pub fn driving(cmpctl: u8) bool {
    return cmpctl & mask.coe != 0;
}

/// The comparator's own verdict, before polarity. There is no analog input
/// in this model, so it is the reset result: plus below reference, low.
pub const verdict: u8 = 0;

/// What CMPMON reads for a channel holding this CMPCTL.
pub fn monitor(cmpctl: u8) u8 {
    if (!operating(cmpctl)) return 0;
    return if (inverted(cmpctl)) verdict ^ cmpmon else verdict;
}
