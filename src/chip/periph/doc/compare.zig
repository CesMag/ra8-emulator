//! The DOC comparator's detection condition: which relation DOCR.DCSEL asks for.
//!
//! In compare mode (DOCR.OMS == 00) a DODIR write moves no accumulator; it only
//! asks a question, and DCSEL[2:0] (DOCR bits 6:4) picks which one. Four of the
//! six relations weigh DODIR against DODSR0 alone; the two window relations put
//! DODIR between DODSR0 (the lower bound) and DODSR1 (the upper), which is the
//! only thing in this part that reads DODSR1 at all. Until now DODSR1 was a
//! register that took writes and answered them and nothing else, and every
//! encoding but "match" collapsed into "mismatch", so a window comparison
//! latched DOPCF on every value outside `DODIR == DODSR0`, window or not.
//!
//! The live consumers are ra8_doc_set_window() and ra8_doc_window_compare() in
//! libs/ra8_hal/src/ra8_doc.c on zig/dev: set_window writes DOCR with DCSEL 4
//! or 5, DODSR0 = lower, DODSR1 = upper, and window_compare then writes DODIR
//! and reads DOPCF back out of DOSR.
//!
//! Encodings, from ra8_docr_dcsel_t in ra8_doc_regs.h (HUM Ch 57.2.1 p 3519):
//!
//!   0 mismatch  DODSR0 != DODIR
//!   1 match     DODSR0 == DODIR
//!   2 lower     DODSR0 >  DODIR
//!   3 upper     DODSR0 <  DODIR
//!   4 inside    DODSR0 <  DODIR <  DODSR1
//!   5 outside   DODIR  <  DODSR0 or DODSR1 < DODIR
//!
//! Every comparison is strict: a DODIR equal to either bound satisfies neither
//! window relation, which the header states outright ("Boundary values do NOT
//! satisfy either window condition").
//!
//! NOT MODELLED, AND NOT GUESSED: encodings 6 and 7. Both trees call them
//! reserved and the HAL asserts they are never written, so they are treated as
//! the reset relation (mismatch) and named as reserved rather than given an
//! invented shape.
const std = @import("std");

/// DOCR.DCSEL[2:0] field geometry (HUM Ch 57.2.1 p 3519).
pub const field = struct {
    pub const mask: u8 = 0x70;
    pub const shift: u3 = 4;
};

/// The detection condition a comparison answers.
pub const Relation = enum(u3) {
    mismatch = 0,
    match = 1,
    lower = 2,
    upper = 3,
    inside = 4,
    outside = 5,
    _,

    /// The relation DOCR currently selects.
    pub fn of(docr: u8) Relation {
        return @fromBackingInt(@intCast(@as(u3, @truncate((docr & field.mask) >> field.shift))));
    }

    /// Whether this relation reads DODSR1 as an upper bound.
    pub fn windowed(self: Relation) bool {
        return self == .inside or self == .outside;
    }

    pub fn name(self: Relation) []const u8 {
        return switch (self) {
            .mismatch => "DODSR0 != DODIR",
            .match => "DODSR0 == DODIR",
            .lower => "DODSR0 > DODIR",
            .upper => "DODSR0 < DODIR",
            .inside => "inside window",
            .outside => "outside window",
            _ => "reserved condition",
        };
    }
};

/// Does the relation hold for this operand? `input`, `reference` and `upper`
/// are DODIR, DODSR0 and DODSR1, each already masked to the DOBW width.
pub fn hit(relation: Relation, input: u32, reference: u32, upper: u32) bool {
    return switch (relation) {
        .match => input == reference,
        .lower => reference > input,
        .upper => reference < input,
        .inside => reference < input and input < upper,
        .outside => input < reference or upper < input,
        // Encoding 0, and the two reserved encodings with it: the reset
        // relation, which is the one dev modelled for every non-match code.
        else => input != reference,
    };
}
