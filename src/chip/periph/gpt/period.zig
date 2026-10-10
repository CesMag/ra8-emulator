//! GTPR and GTPBR: the period a channel wraps at, and the one waiting to
//! become it.
//!
//! GTPR sits at +0x64 and GTPBR, its buffer, at +0x68 (ra8_gpt_regs.h lines
//! 79..80, `R_GPT0.GTPR` "Period" and `R_GPT0.GTPBR` "Period buffer"). The
//! live register was a plain `u32` on the channel and GTPBR was not
//! interpreted at all, so a store to it fell through to the window shadow:
//! readable, and inert.
//!
//! THAT IS THE ONLY WAY THE HAL CHANGES A RUNNING CHANNEL'S PERIOD. Both
//! period setters write the buffer unconditionally and touch the live
//! register only when the counter is stopped. `ra8_gpt_period_set`
//! (ra8_gpt.c line 600) is the shape of it:
//!
//!     reg->GTPBR = period_counts;
//!     if ((reg->GTCR & k_ra8_gpt_gtcr_cst_mask) == 0U) {
//!       reg->GTPR  = period_counts;
//!       reg->GTCNT = 0U;
//!     }
//!
//! and `ra8_gpt_set_period` (line 388) does the same. The driver's own
//! contract says what the part then does with the buffer, twice, in
//! ra8_gpt.h line 347: "Writes ``period_counts`` to GTPBR; on the next
//! overflow the timer loads GTPBR into GTPR", and again at line 364 as a
//! postcondition, "On the next overflow GTPR is reloaded from GTPBR". It
//! cites HUM Ch 22.2.21 "GTPR" p 938 and Ch 22.2.17 "GTBER" p 932..935.
//!
//! So against the old model every runtime period change on a RUNNING channel
//! returned success and changed nothing. GTCNT went on wrapping at the period
//! `ra8_gpt_init` gave it for the rest of the run, the overflow rate the
//! report printed was the old rate, and a driver stepping a PWM frequency up
//! read back the period it asked for out of the shadow while the counter
//! ignored it. A stopped channel was never affected, which is why the gap
//! hid: the demos that set a period once, before starting, were right.
//!
//! THE TRANSFER IS UNCONDITIONAL HERE, AND THAT IS A DELIBERATE CHOICE
//! rather than an invented enable. GTBER's compare halves are modelled from
//! bit positions ra8_gpt.c names (`k_ra8_gpt_gtber_ccra_single`
//! 0x0001_0000, `ccrb_single` 0x0004_0000), so buffer.zig can ask
//! whether firmware enabled a duty transfer. Neither this tree nor
//! ra8-firmware carries a position for GTBER's PERIOD buffer field, and the
//! HAL never writes one: it parks the value and documents the reload with no
//! precondition at all. Guessing a bit number to gate this on would be
//! guessing; the reload therefore happens whenever firmware has actually
//! parked a period, and if a later HUM read turns up an enable bit, this is
//! the one place it goes.
//!
//! A CHANNEL THAT NEVER WROTE GTPBR IS UNTOUCHED, which is the other half of
//! not guessing. GTPBR's reset value is not carried here either, so an
//! unwritten buffer is not handed over: it would mean inventing a number and
//! feeding it to the counter at the first wrap. The buffer only becomes live
//! once a store has put something in it.
//!
//! NOT MODELLED, AND NOT GUESSED: GTPDBR (+0x6C), the double buffer, which
//! stays shadow storage the way buffer.zig leaves the compare side's
//! double buffering alone.
const std = @import("std");

/// Where the live register and its buffer sit in a channel
/// (ra8_gpt_regs.h lines 79..80).
pub const off = struct {
    pub const gtpr: u32 = 0x64;
    pub const gtpbr: u32 = 0x68;
};

/// The period a zero GTPR stands for, carried from dev: a channel started
/// before its period is loaded still counts, to the 16-bit wrap.
pub const default: u32 = 0xFFFF;

/// Which of the pair an access landed on.
pub const Which = enum { live, buffer };

/// One channel's period and the value parked to replace it.
pub const Period = struct {
    live: u32 = 0,
    buffer: u32 = 0,
    /// Has firmware put anything in the buffer? An untouched buffer is not
    /// handed over, because its reset value is not known here.
    parked: bool = false,
    /// Transfers made at a cycle end.
    loads: u32 = 0,
    /// Transfers that actually moved the period, so an image that parks the
    /// period it already had is distinguishable from one that changed it.
    changes: u32 = 0,

    /// The period the counter wraps at.
    pub fn span(self: *const Period) u32 {
        return if (self.live == 0) default else self.live;
    }

    pub fn value(self: *const Period, part: Which) u32 {
        return switch (part) {
            .live => self.live,
            .buffer => self.buffer,
        };
    }

    pub fn set(self: *Period, part: Which, new_value: u32) void {
        switch (part) {
            .live => self.live = new_value,
            .buffer => {
                self.buffer = new_value;
                self.parked = true;
            },
        }
    }

    /// Take the buffer up as the live period, the way the end of a counting
    /// cycle does. Nothing happens until firmware has parked something.
    pub fn reload(self: *Period) void {
        if (!self.parked) return;
        self.loads +%= 1;
        if (self.buffer != self.live) {
            self.changes +%= 1;
            self.live = self.buffer;
        }
    }

    pub fn quiet(self: *const Period) bool {
        return !self.parked and self.live == 0 and self.loads == 0;
    }
};

/// Which of the pair a channel-local offset belongs to, or null when the
/// offset is neither.
pub fn which(local: u32) ?Which {
    if (local >= off.gtpr and local < off.gtpr + 4) return .live;
    if (local >= off.gtpbr and local < off.gtpbr + 4) return .buffer;
    return null;
}
