//! GPT compare match: the compare/capture values a channel carries, and
//! whether the up-counter has passed one.
//!
//! GTCCRA and GTCCRB were storage here. A store landed in the channel's
//! shadow, a read gave the value back, and nothing ever looked at it, so
//! GTST.TCFA could not rise and an image waiting on a compare match waited
//! out its whole budget. dev's board_periph_timer.c has the same hole from a
//! different direction: it names k_gtst_tcfa in its status enumeration and
//! then raises only TCFPO, and it answers zero to every offset outside the
//! seven it interprets, so on that tree GTCCRA does not even read back.
//!
//! The six compare/capture registers sit at +0x4C through +0x60, one word
//! each, from ra8-firmware's ra8_gpt_regs.h on zig/dev (`GTCCR[6]`, between
//! GTCNT at +0x48 and GTPR at +0x64). That header is what the GPT file's own
//! note said did not exist; it does, so A and B are compared here. The two
//! buffer halves, GTCCR[2] and GTCCR[3], now feed A and B at the end of a
//! cycle through src/chip/periph/gpt/buffer.zig, which reads GTBER. GTCCRD and
//! GTCCRF stay shadowed: they are capture registers and there is no capture
//! input in this model.
//!
//! THE FLAG POSITIONS. dev's enumeration gives three of GTST's bits by name:
//! TCFA bit 0, TCFPO bit 6, TCFPU bit 7. TCFB is not in it. Bit 1 is taken
//! for it here because the three that ARE named are exactly the HUM ordering
//! that runs TCFA..TCFF through bits 0..5 with the two period flags above
//! them, and because a compare B that shares A's flag would make the report
//! lie about which register matched. It is a derivation from the bits dev
//! names, not a bit table anyone in either tree has written down.
//!
//! MODEL'S OWN RULE, carried from the AGT and ULPT files for the same reason:
//! a compare value of zero is unarmed. The per-source enables live in GTINTAD
//! at +0x38, which this tree does not interpret, and without them a compare
//! sitting at its reset value of zero would match on every wrap of every
//! channel a firmware happens to start.
//!
//! NOT MODELLED, AND NOT GUESSED: the compare-match interrupt. GPT0's counter
//! overflow is the one event number this tree carries for the block, so a
//! match sets its flag and is counted and the event path still sees only the
//! overflow. Nothing here writes to the counter either: compare match in PWM
//! mode clears GTCNT through GTCR's mode bits, and those are not modelled, so
//! the period is still the only thing that wraps the count.
const std = @import("std");

/// Where the compare/capture array sits in a channel (ra8_gpt_regs.h).
pub const off = struct {
    pub const gtccra: u32 = 0x4C;
    pub const gtccrb: u32 = 0x50;
    /// A..F, of which this file compares the first two.
    pub const registers: usize = 6;
};

/// GTST compare-match flags. TCFA is dev's; TCFB is derived (see the header).
pub const flag = struct {
    pub const tcfa: u32 = 0x0000_0001;
    pub const tcfb: u32 = 0x0000_0002;
    pub const both: u32 = tcfa | tcfb;
};

/// Which of the two compares a crossing belongs to.
pub const Which = enum { a, b };

/// The pair of compare values for one channel, and what they have matched.
pub const Pair = struct {
    a: u32 = 0,
    b: u32 = 0,
    matches_a: u32 = 0,
    matches_b: u32 = 0,
    /// Writes of either register, so an image that programs a compare and
    /// never reaches it still shows up in the report.
    writes: u32 = 0,

    pub fn quiet(self: *const Pair) bool {
        return self.writes == 0 and self.matches_a == 0 and self.matches_b == 0;
    }

    /// A compare value of zero is unarmed (see the model rule in the header).
    pub fn armed(self: *const Pair, side: Which) bool {
        return self.value(side) != 0;
    }

    pub fn value(self: *const Pair, side: Which) u32 {
        return switch (side) {
            .a => self.a,
            .b => self.b,
        };
    }

    pub fn matches(self: *const Pair, side: Which) u32 {
        return switch (side) {
            .a => self.matches_a,
            .b => self.matches_b,
        };
    }

    pub fn set(self: *Pair, side: Which, new_value: u32) void {
        switch (side) {
            .a => self.a = new_value,
            .b => self.b = new_value,
        }
        self.writes +%= 1;
    }

    /// Take a value from the buffer register at the end of a cycle. The
    /// transfer is the hardware's, not a firmware store, so it does not
    /// count as a write: the buffer side counts its own reloads.
    pub fn load(self: *Pair, side: Which, new_value: u32) void {
        switch (side) {
            .a => self.a = new_value,
            .b => self.b = new_value,
        }
    }

    /// The flags a chunk of counting from `before` up to `after` raises.
    /// `wraps` is how many times the chunk went past `period`. A compare set
    /// above the period is a value GTCNT never holds, so it never matches
    /// however often the saw wraps (RA8EMU-590).
    pub fn step(self: *Pair, before: u32, after: u32, wraps: u32, period: u32) u32 {
        var raised: u32 = 0;
        if (self.armed(.a) and self.a <= period and crossed(before, after, wraps, self.a)) {
            self.matches_a +%= 1;
            raised |= flag.tcfa;
        }
        if (self.armed(.b) and self.b <= period and crossed(before, after, wraps, self.b)) {
            self.matches_b +%= 1;
            raised |= flag.tcfb;
        }
        return raised;
    }

    /// The flags a chunk that visited every count in [lo, hi] raises. This is
    /// the triangle's entry point: a chunk that turned is not an up-count, so it
    /// is described by the span it covered instead of by a direction. A target
    /// sitting exactly where the chunk started was not passed by it.
    pub fn stepSpan(self: *Pair, before: u32, lo: u32, hi: u32) u32 {
        var raised: u32 = 0;
        if (self.armed(.a) and within(before, lo, hi, self.a)) {
            self.matches_a +%= 1;
            raised |= flag.tcfa;
        }
        if (self.armed(.b) and within(before, lo, hi, self.b)) {
            self.matches_b +%= 1;
            raised |= flag.tcfb;
        }
        return raised;
    }
};

/// Did an up-count from `before` to `after` pass `target`?
///
/// Without a wrap the chunk covers (before, after]. One wrap is that span cut
/// in two: everything above where the count started, plus everything from
/// zero up to where it ended. Two wraps or more visits every value in the
/// period at least once, so anything armed matched.
pub fn crossed(before: u32, after: u32, wraps: u32, target: u32) bool {
    if (wraps >= 2) return true;
    if (wraps == 1) return target > before or target <= after;
    return target > before and target <= after;
}

/// Did a chunk covering [lo, hi] pass `target`?
pub fn within(before: u32, lo: u32, hi: u32, target: u32) bool {
    return target >= lo and target <= hi and target != before;
}

/// The register a channel-local offset belongs to, or null when it is not one
/// of the two this file compares.
pub fn which(local: u32) ?Which {
    if (local >= off.gtccra and local < off.gtccra + 4) return .a;
    if (local >= off.gtccrb and local < off.gtccrb + 4) return .b;
    return null;
}
