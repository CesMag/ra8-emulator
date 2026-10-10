//! The AGT compare-match function: whether a compare is armed at all.
//!
//! AGTCMSR sits at +0x0E in every channel's window (ra8_agt_regs.h,
//! HUM Ch 24.2.9 p 1172) and carries three bits per side:
//!
//!   TCMEA  b0   compare match A enable      TCMEB  b4
//!   TOEA   b1   AGTOAn output enable        TOEB   b5
//!   TOPOLA b2   AGTOAn output polarity      TOPOLB b6
//!
//! The enable is what decides whether a count passing the compare value does
//! anything; the other two are about the pin the match drives.
//!
//! This register was a shadow byte here, so the model had no way to tell an
//! armed compare from a parked one and used a rule of its own instead: a
//! compare value of zero counts as unarmed. That rule is wrong at both ends.
//! A driver that parks a side writes 0xFFFF into it, not zero
//! (`k_ra8_agt_compare_parked_value`, ra8_agt.c line 537), so a parked side
//! still matched; and a channel that never enabled the function at all still
//! raised TCMAF, which is the case every image in this tree was in.
//! ra8_agt_pulse_init (ra8_agt.c line 615) writes the enable bit and its
//! output bit together, and both teardown paths write AGTCMSR = 0
//! (lines 764, and the deinit that follows it), so the bit really is the
//! driver's own switch.
//!
//! NOT MODELLED, AND NOT GUESSED: TOEA/TOEB and TOPOLA/TOPOLB. They select
//! and invert an output pin, and there is no pin in a headless run to show
//! it on, so they ride in the register and are never read. A compare that is
//! enabled matches whether or not its output is enabled, which is what the
//! flag does on silicon.

/// AGTCMSR's offset in a channel's window (ra8_agt_regs.h).
pub const off_cmsr: u32 = 0x0E;

/// AGTCMSR bit masks (HUM Ch 24.2.9 p 1172).
pub const mask = struct {
    pub const tcmea: u8 = 0x01;
    pub const toea: u8 = 0x02;
    pub const topola: u8 = 0x04;
    pub const tcmeb: u8 = 0x10;
    pub const toeb: u8 = 0x20;
    pub const topolb: u8 = 0x40;
};

/// The two compare sides, each with its own three bits.
pub const Side = enum {
    a,
    b,

    pub fn enable(self: Side) u8 {
        return switch (self) {
            .a => mask.tcmea,
            .b => mask.tcmeb,
        };
    }

    pub fn output(self: Side) u8 {
        return switch (self) {
            .a => mask.toea,
            .b => mask.toeb,
        };
    }

    pub fn name(self: Side) []const u8 {
        return switch (self) {
            .a => "A",
            .b => "B",
        };
    }
};

/// Whether a count passing this side's compare value raises its flag.
pub fn enabled(cmsr: u8, side: Side) bool {
    return cmsr & side.enable() != 0;
}

/// Whether the match also drives this side's output pin. Nothing reads this
/// yet; it is here so the pin, when something models one, does not have to
/// re-derive the bit.
pub fn driving(cmsr: u8, side: Side) bool {
    return enabled(cmsr, side) and cmsr & side.output() != 0;
}
