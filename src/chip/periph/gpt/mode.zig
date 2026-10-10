//! GTCR.MD: the shape a GPT channel counts in.
//!
//! GTCR (+0x2C) carries MD at bits 16..19 (ra8_gpt.c `ra8_gpt_gtcr_bits_t`,
//! `k_ra8_gpt_gtcr_md_shift = 16`, citing HUM Ch 22.2.5 "GTCR : General PWM
//! Timer Control Register" p 904..906). `ra8_gpt_mode_t` in ra8_gpt.h names
//! five encodings and no others:
//!
//!   0  saw-wave PWM, up-count
//!   1  saw-wave one-shot
//!   4  triangle-wave PWM, symmetric
//!   5  triangle-wave PWM 1
//!   6  triangle-wave PWM 2
//!
//! The field was stored and never read, so every channel counted up and
//! wrapped whatever its driver selected. `ra8_gpt_init` writes the mode on
//! every channel it brings up (line 345, `internal_gtcr(cfg->mode, ...)`) and
//! `ra8_gpt_three_phase_init` hands the same one to all three motor channels,
//! so a triangle channel sawed: a driver sampling GTCNT to find which half of
//! the cycle it was in read a ramp that only ever rose, and a one-shot
//! channel kept counting forever instead of stopping at the period. dev's
//! board_periph_timer.c has the same hole.
//!
//! A TRIANGLE COUNTS UP AND BACK DOWN. The cycle is twice the period: the
//! count rises to GTPR, turns, falls to zero, and turns again. Reaching the
//! period is the overflow (GTST.TCFPO) and returning to zero is the underflow
//! (GTST.TCFPU), which is the bit dev names and nothing in this tree could
//! raise before. A chunk of counting wider than the cycle folds, so the
//! direction after it is where the fold landed, not where it started.
//!
//! A ONE-SHOT STOPS AT THE PERIOD. It counts up once, raises the overflow,
//! and clears GTCR.CST, so the count stands at GTPR and a driver polling for
//! the stop sees it. That is the model's reading of "one-shot": the part also
//! holds the output at its final level, and there is no output here.
//!
//! A MODE SELECTED IS NOT A MODE COUNTED IN. MD is stored in GTCR beside
//! CST, so a driver that writes the whole control word to start a channel
//! also rewrites the shape, and nothing said so. `ra8_gpt_start_free_run`
//! does exactly that: it writes `GTCR = 0x00000001`, which is CST with MD
//! zero, so a channel `ra8_gpt_init` had configured as a one-shot counts as
//! saw PWM from the first start onward and never stops at its period. The
//! one-shot demo reaches this: it arms MD = 1, then starts, and the run
//! reported an ordinary free-running saw with nothing to say the shape it
//! asked for had been taken away. `Log` below remembers the first shape MD
//! was ever moved to and how many times it moved, so the report can name
//! both the shape a channel asked for and the one it actually counted in.
//!
//! NOT MODELLED, AND NOT GUESSED: what separates the three triangle
//! encodings. ra8_gpt.h names 4, 5 and 6 as "symmetric", "PWM 1" and "PWM 2",
//! and neither tree says how their duty loading differs; they count the same
//! triangle here, which is the part of the difference GTCNT can show. The
//! encodings nobody names (2, 3 and 7..15) count in saw mode rather than
//! being given an invented shape, and `name()` says the mode is unknown so
//! the run does not claim to have recognised it.
const std = @import("std");

/// Where MD sits in GTCR (ra8_gpt.c, HUM Ch 22.2.5 p 904..906).
pub const field = struct {
    pub const md: u32 = 0x000F_0000;
    pub const shift: u5 = 16;
};

/// The MD encodings ra8_gpt.h names.
pub const Mode = enum(u32) {
    saw_pwm = 0,
    saw_one_shot = 1,
    triangle_pwm = 4,
    triangle_pwm2 = 5,
    triangle_pwm3 = 6,
    _,

    /// Does the count come back down after the period?
    pub fn symmetric(self: Mode) bool {
        return switch (self) {
            .triangle_pwm, .triangle_pwm2, .triangle_pwm3 => true,
            else => false,
        };
    }

    /// Does the channel stop itself at the end of one period?
    pub fn once(self: Mode) bool {
        return self == .saw_one_shot;
    }

    pub fn name(self: Mode) []const u8 {
        return switch (self) {
            .saw_pwm => "saw PWM",
            .saw_one_shot => "saw one-shot",
            .triangle_pwm => "triangle PWM",
            .triangle_pwm2 => "triangle PWM 1",
            .triangle_pwm3 => "triangle PWM 2",
            _ => "unknown counter mode",
        };
    }
};

/// The mode GTCR selects.
pub fn modeOf(cr: u32) Mode {
    return @fromBackingInt(@intCast((cr & field.md) >> field.shift));
}

/// What GTCR.MD has been set to over a channel's life. GTCR is written a
/// byte at a time, and MD sits in byte 2, so only a store that actually
/// moves the field counts: the other three bytes of a word store leave it
/// where it was and are not a mode change.
pub const Log = struct {
    /// The first shape MD was ever moved to, or null if it never moved.
    first: ?Mode = null,
    /// Stores that moved MD to a different encoding.
    changes: u32 = 0,

    /// Take a GTCR store. `after` is the word the access leaves behind and
    /// is returned unchanged, so a caller can write `cr = log.note(cr, x)`.
    pub fn note(self: *Log, before: u32, after: u32) u32 {
        const now = modeOf(after);
        if (now == modeOf(before)) return after;
        if (self.first == null) self.first = now;
        self.changes += 1;
        return after;
    }

    /// Did a later store move the channel off the shape it first asked for?
    pub fn overwritten(self: Log, now: Mode) bool {
        const first = self.first orelse return false;
        return first != now;
    }

    /// A channel whose MD never moved has nothing to report.
    pub fn quiet(self: Log) bool {
        return self.first == null;
    }
};

/// Where one chunk of counting left a channel.
pub const Step = struct {
    cnt: u32,
    /// Which way the count is going now. Always true outside a triangle.
    rising: bool = true,
    /// Times the count reached the period: GTST.TCFPO.
    peaks: u32 = 0,
    /// Times a triangle came back to zero: GTST.TCFPU.
    troughs: u32 = 0,
    /// A one-shot finished, so the channel clears its own start bit.
    halted: bool = false,
};

/// Count `delta` from `cnt` in the shape `mode` selects. `period` is the
/// channel's GTPR with its zero already resolved, so it is never zero.
pub fn advance(mode: Mode, cnt: u32, rising: bool, period: u32, delta: u64) Step {
    if (mode.symmetric()) return fold(cnt, rising, period, delta);
    const next = @as(u64, cnt) + delta;
    if (mode.once()) {
        if (next <= period) return .{ .cnt = @intCast(next) };
        return .{ .cnt = period, .peaks = 1, .halted = true };
    }
    const span = @as(u64, period) + 1;
    if (next <= period) return .{ .cnt = @intCast(next) };
    return .{ .cnt = @intCast(next % span), .peaks = @intCast(next / span) };
}

/// The triangle. A position on the rising half is the count itself; one on
/// the falling half is the cycle less the count, so the whole ramp is a
/// single phase that advances and folds back.
fn fold(cnt: u32, rising: bool, period: u32, delta: u64) Step {
    const cycle = 2 * @as(u64, period);
    if (cycle == 0) return .{ .cnt = 0 };
    const phase = if (rising) @as(u64, cnt) else cycle - @min(@as(u64, cnt), cycle);
    const total = phase + delta;
    const landed = total % cycle;
    return .{
        .cnt = if (landed <= period) @intCast(landed) else @intCast(cycle - landed),
        .rising = landed < period,
        .peaks = @intCast(reached(total, period, cycle) - reached(phase, period, cycle)),
        .troughs = @intCast(total / cycle),
    };
}

/// How many peaks a phase of 0 up to `at` has passed. A peak sits at
/// `period` and every cycle after it, so the count of them in a chunk is the
/// difference between the two ends.
fn reached(at: u64, period: u32, cycle: u64) u64 {
    if (at < period) return 0;
    return (at - period) / cycle + 1;
}

/// The counts a chunk visited, so a compare can tell whether it was passed.
/// A turn widens the span to the end it turned at: reaching the period means
/// everything up to it was seen, and returning to zero means everything down
/// to it was.
pub const Span = struct {
    lo: u32,
    hi: u32,
};

pub fn visited(before: u32, step: Step, period: u32) Span {
    return .{
        .lo = if (step.troughs != 0) 0 else @min(before, step.cnt),
        .hi = if (step.peaks != 0) period else @max(before, step.cnt),
    };
}

/// Did this chunk finish a counting cycle? A saw's cycle ends where it wraps
/// and a one-shot's at the single peak that stops it, both of which are a
/// peak; a triangle's ends where it comes back to zero, which is a trough.
/// The end of a cycle is when a channel takes up its buffered compares and
/// its buffered period.
pub fn endedCycle(kind: Mode, moved: Step) bool {
    if (kind.symmetric()) return moved.troughs != 0;
    return moved.peaks != 0;
}
