//! ULPT compare match: the two values ULPTCMA and ULPTCMB, and whether the
//! down-counter has passed one.
//!
//! Until now ULPTCMA and ULPTCMB were storage. The unit took the write, gave
//! the value back on a read, counted the access, and the end-of-run report
//! said so in capitals: a compare was stored and never compared, so no flag
//! ever rose and an image waiting on one waited out its whole budget. dev's
//! board_periph_ulpt.c has the same hole from the same direction.
//!
//! ULPTCR shares AGTCR's layout (HUM Ch 25.2.1 p 1190, mirroring Ch 24.2.6
//! p 1175), which is what the ULPT file header has said since it was ported,
//! so the flags are AGTCR's flags at AGTCR's positions: TCMAF bit 6, TCMBF
//! bit 7, above TUNDF at bit 5. The AGT model in this tree raises those two
//! already; this is the same rule for the low-power channel.
//!
//! MODEL'S OWN RULE, not a register, carried over from the AGT file for the
//! same reason: a compare value of zero is unarmed. The real enable bits live
//! in a register no header in either tree gives an offset for, and without
//! them an armed-at-zero compare would match on every wrap.
//!
//! NOT MODELLED, AND NOT GUESSED: the compare-match interrupts. ULPT0's
//! combined ULPTI event is the one number this tree carries for the block, so
//! a match sets its flag and is counted, and the event path still only sees
//! the underflow.
//!
//! A NOTE ON THE UNDERFLOW BIT, because the two trees disagree and this file
//! does not settle it. ra8-firmware's ra8_ulpt_regs.h numbers ULPTCR as TUNF
//! bit 4, TEDGA bit 5, TEDGB bit 6. dev's board_periph_ulpt.c, this model and
//! the ulpt image all use bit 5 for the underflow. The firmware driver never
//! reads any of the three, so nothing on that side depends on it. TUNDF is
//! left where the two emulator trees and the image already agree, and the
//! compare flags sit above it in AGTCR's order rather than moving it on a
//! header this tree cannot check against the manual.
const std = @import("std");

/// ULPTCR status flags, in AGTCR's order.
pub const flag = struct {
    pub const undf: u8 = 0x20;
    pub const cmaf: u8 = 0x40;
    pub const cmbf: u8 = 0x80;
    /// The bits a control write can keep rather than set.
    pub const all: u8 = undf | cmaf | cmbf;
};

/// Which of the two compares a crossing belongs to.
pub const Which = enum { a, b };

/// The pair of compare values for one channel, and what they have matched.
pub const Pair = struct {
    a: u32 = 0,
    b: u32 = 0,
    matches_a: u32 = 0,
    matches_b: u32 = 0,
    /// Reads and writes of either register, so an image that only programs a
    /// compare and never reaches one still shows up in the report.
    touches: u32 = 0,

    pub fn quiet(self: *const Pair) bool {
        return self.touches == 0 and self.matches_a == 0 and self.matches_b == 0;
    }

    /// A compare value of zero is unarmed (see the model rule in the header).
    pub fn armed(self: *const Pair, which: Which) bool {
        return self.value(which) != 0;
    }

    pub fn value(self: *const Pair, which: Which) u32 {
        return switch (which) {
            .a => self.a,
            .b => self.b,
        };
    }

    pub fn matches(self: *const Pair, which: Which) u32 {
        return switch (which) {
            .a => self.matches_a,
            .b => self.matches_b,
        };
    }

    /// Record a read or write of one of the two registers.
    pub fn touch(self: *Pair) void {
        self.touches +%= 1;
    }

    pub fn set(self: *Pair, which: Which, new_value: u32) void {
        switch (which) {
            .a => self.a = new_value,
            .b => self.b = new_value,
        }
        self.touch();
    }

    /// The flags a chunk of counting from `before` to `after` raises. Counting
    /// down, so `wrapped` says the chunk went through the reload.
    pub fn step(self: *Pair, before: u32, after: u32, wrapped: bool, reload: u32) u8 {
        var raised: u8 = 0;
        if (self.armed(.a) and crossed(before, after, wrapped, reload, self.a)) {
            self.matches_a +%= 1;
            raised |= flag.cmaf;
        }
        if (self.armed(.b) and crossed(before, after, wrapped, reload, self.b)) {
            self.matches_b +%= 1;
            raised |= flag.cmbf;
        }
        return raised;
    }
};

/// Did a down-count from `before` to `after` pass `target`?
///
/// Without a wrap the chunk covers (after, before], so the target has to sit
/// below where the count started and at or above where it ended. With a wrap
/// the chunk is that same span plus everything from the reload down to the
/// new count, which is the half the AGT model gets right and dev does not
/// model at all.
pub fn crossed(before: u32, after: u32, wrapped: bool, reload: u32, target: u32) bool {
    if (!wrapped) return target < before and target >= after;
    return target < before or (target >= after and target <= reload);
}
