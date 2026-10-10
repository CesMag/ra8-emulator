//! The RTC software reset: RCR2.RESET, a command bit rather than a setting.
//!
//! RCR2 sits at +0x24 in the RTC window and carries eight bits
//! (ra8_rtc_regs.h `ra8_rcr2_bit_t`, HUM Ch 26.2.4 p 1230):
//!
//!   START 0   RESET 1   ADJ30 2   RTCOE 3
//!   AADJE 4   AADJP 5   HR24  6   CNTMD 7
//!
//! Seven of them hold a setting firmware writes and reads back. RESET does
//! not. The header calls it "Software reset (write 1, auto-clear)", and the
//! driver's clock bring-up leans on exactly that: ra8_rtc_clk_init writes
//! the bit on its own, waits the settle the part asks for, and then POLLS
//! THE BIT UNTIL IT FALLS (ra8_rtc.c lines 297-302):
//!
//!     rtc->RCR2 = (uint8_t)(1U << k_ra8_rcr2_bit_reset);
//!     ra8_delay_ms((uint32_t)k_ra8_rtc_clk_reset_ms);
//!     internal_wait_bit(&rtc->RCR2, (uint8_t)(1U << k_ra8_rcr2_bit_reset), 0U);
//!
//! The whole RTC window was a faithful shadow, so that store landed in the
//! shadow and read back as 1 for the rest of the run: firmware taking the
//! driver's own bring-up path spun in that poll until the instruction
//! budget ran out, with nothing in the report to say why. The bit is
//! interpreted here instead. It never lands, so it reads back as the zero
//! the poll is waiting for, and the reset it asked for is performed once
//! and counted.
//!
//! NOT MODELLED, AND NOT GUESSED: the full list of registers the reset
//! initialises. Neither the header nor the driver names one, and the HUM
//! page that would is not in this tree, so the reset clears the sub-second
//! prescaler, which is the piece of counting state this model owns, and
//! leaves the calendar counters, the alarm registers and RCR1 alone. A
//! later fire with the HUM page in hand can widen it; inventing the list
//! now would silently wipe a time firmware had just written.
//!
//! ADJ30, AADJE and AADJP ride in the register and are never read: they are
//! clock trimming against a real 32.768 kHz crystal, and a modelled second
//! has nothing to trim. RTCOE drives the RTCOUT pin, and there is no pin in
//! a headless run to show it on.

/// RCR2's offset in the RTC window (ra8_rtc_regs.h).
pub const off_rcr2: u32 = 0x24;

/// RCR2 bit masks (HUM Ch 26.2.4 p 1230).
pub const mask = struct {
    pub const start: u8 = 0x01;
    pub const reset: u8 = 0x02;
    pub const adj30: u8 = 0x04;
    pub const rtcoe: u8 = 0x08;
    pub const aadje: u8 = 0x10;
    pub const aadjp: u8 = 0x20;
    pub const hr24: u8 = 0x40;
    pub const cntmd: u8 = 0x80;
};

/// What the counters count in. CNTMD picks it, and the driver confirms the
/// mode by polling the bit back (ra8_rtc.c line 317).
pub const Mode = enum {
    calendar,
    binary,

    pub fn of(rcr2: u8) Mode {
        return if (rcr2 & mask.cntmd != 0) .binary else .calendar;
    }

    pub fn name(self: Mode) []const u8 {
        return switch (self) {
            .calendar => "calendar",
            .binary => "binary",
        };
    }
};

/// Whether this store asked for the software reset.
pub fn requested(byte: u8) bool {
    return byte & mask.reset != 0;
}

/// What the store leaves behind. The command bit auto-clears, so it is
/// never part of the value firmware reads back.
pub fn stored(byte: u8) u8 {
    return byte & ~mask.reset;
}

/// Whether the counters advance.
pub fn running(byte: u8) bool {
    return byte & mask.start != 0;
}

/// Whether the hour counter is 24-hour. The driver polls this one back too
/// (ra8_rtc.c lines 327-330).
pub fn hours24(byte: u8) bool {
    return byte & mask.hr24 != 0;
}
