//! GTBER: the compare a channel takes up at the end of a cycle.
//!
//! GTBER sits at +0x40 (ra8_gpt_regs.h, `R_GPT0.GTBER`, "Buffer Enable").
//! Its CCRA field is bits 16..17 and its CCRB field is bits 18..19, and
//! setting the lower bit of a pair selects single-buffer operation: the value
//! firmware parked in the buffer register moves into the live compare at the
//! end of the counting cycle. That is ra8_gpt.c's `ra8_gpt_buffer_bits_t`
//! (`k_ra8_gpt_gtber_ccra_single` 0x0001_0000, `k_ra8_gpt_gtber_ccrb_single`
//! 0x0004_0000), citing HUM Ch 22.2.17 "GTBER" p 932..935. The buffer that
//! feeds GTCCRA is GTCCR[2] at +0x54 and the one that feeds GTCCRB is
//! GTCCR[3] at +0x58; the driver names them C and E (`ra8_gpt_ccr_idx_t`,
//! HUM Ch 22.2.20 "GTCCRA..F" p 938).
//!
//! The register was shadow storage here and both buffers were among the four
//! compare/capture words compare.zig deliberately left alone, so nothing
//! carried a parked value across. That is not a small gap: the HAL's only
//! runtime duty setter never touches the live register at all.
//! `ra8_gpt_duty_cycle_set` (ra8_gpt.c line 613) writes the new compare into
//! GTCCR[2] or GTCCR[3] and asserts the matching GTBER bit, and
//! `ra8_gpt_three_phase_set_duty` (line 833) does the same for all three
//! motor channels. Against the old model every one of those calls returned
//! success and changed nothing: GTCCRA kept the duty `ra8_gpt_init` gave it,
//! GTST.TCFA went on matching the old value forever, and a driver ramping a
//! motor read back a compare that never moved. The GPT file's own note said
//! a buffered duty "takes effect at once", which was the optimistic reading;
//! it never took effect.
//!
//! WHERE THE CYCLE ENDS. A saw's cycle ends where it wraps, a one-shot's at
//! the single peak that stops it, and a triangle's when it comes back to
//! zero, which is the whole up-and-down. The part is finer than that: HUM
//! distinguishes crest from trough transfer for the triangle modes, and
//! neither this tree nor ra8-firmware carries that table, so a triangle
//! reloads at the trough here and nothing pretends to know what the crest
//! variants do differently.
//!
//! THE PERIOD IS NOT HERE. GTPBR (+0x68) and the live GTPR are a pair of
//! their own and live in src/chip/periph/gpt/period.zig, which hands the parked
//! period over at the same cycle end this file hands the compares over. That
//! transfer is unconditional, because the HAL documents the reload with no
//! enable and no bit position for GTBER's period field exists in either
//! tree; the reasoning is in that file's header.
//!
//! NOT MODELLED, AND NOT GUESSED: double buffering, which is the upper bit of
//! each GTBER pair, so a pair selecting it gets the single-buffer transfer
//! rather than an invented two-deep queue; GTBER's dead-time buffer field and
//! GTPDBR (+0x6C), the period double buffer; and the buffer-transfer skipping
//! in GTITC, which nothing in either tree programs.
const std = @import("std");

const compare = @import("compare.zig");

/// Where the register and its two buffers sit in a channel (ra8_gpt_regs.h).
pub const off = struct {
    pub const gtber: u32 = 0x40;
    /// GTCCR[2], the buffer GTCCRA reloads from.
    pub const buffer_a: u32 = 0x54;
    /// GTCCR[3], the buffer GTCCRB reloads from.
    pub const buffer_b: u32 = 0x58;
};

/// GTBER's buffer-enable fields (ra8_gpt.c, HUM Ch 22.2.17 p 932..935).
pub const field = struct {
    pub const ccra: u32 = 0x0003_0000;
    pub const ccrb: u32 = 0x000C_0000;
    pub const ccra_single: u32 = 0x0001_0000;
    pub const ccrb_single: u32 = 0x0004_0000;
};

/// Which compare a buffer belongs to. The same two sides compare.zig
/// names, so a caller never has to translate between the halves.
pub const Side = compare.Which;

/// One channel's buffer registers and the enable word that governs them.
pub const Buffers = struct {
    ber: u32 = 0,
    a: u32 = 0,
    b: u32 = 0,
    /// Transfers made, so an image that parks a duty and never completes a
    /// cycle is distinguishable from one that did.
    reloads: u32 = 0,

    /// Is this side's buffer enabled for the single-buffer transfer?
    pub fn single(self: *const Buffers, side: Side) bool {
        const bit = switch (side) {
            .a => field.ccra_single,
            .b => field.ccrb_single,
        };
        return self.ber & bit != 0;
    }

    pub fn value(self: *const Buffers, side: Side) u32 {
        return switch (side) {
            .a => self.a,
            .b => self.b,
        };
    }

    pub fn set(self: *Buffers, side: Side, new_value: u32) void {
        switch (side) {
            .a => self.a = new_value,
            .b => self.b = new_value,
        }
    }

    /// The value this side takes up at the end of a cycle, or null when its
    /// buffer is not enabled. A parked zero is handed over like any other
    /// value, which disarms the compare, because that is what the register
    /// says to do.
    pub fn take(self: *Buffers, side: Side) ?u32 {
        if (!self.single(side)) return null;
        self.reloads +%= 1;
        return self.value(side);
    }

    pub fn quiet(self: *const Buffers) bool {
        return self.ber == 0 and self.reloads == 0;
    }
};

/// The buffer a channel-local offset belongs to, or null when the offset is
/// neither of the two.
pub fn which(local: u32) ?Side {
    if (local >= off.buffer_a and local < off.buffer_a + 4) return .a;
    if (local >= off.buffer_b and local < off.buffer_b + 4) return .b;
    return null;
}
