//! The GPT count source: how fast a channel counts, out of GTCR.
//!
//! GTCR (+0x2C) carries three fields (ra8_gpt.c `ra8_gpt_gtcr_bits_t`, which
//! cites HUM Ch 22.2.x "GTCR : General PWM Timer Control Register" p 904..906):
//! CST at bit 0, MD at bits 16..19, and TPCS at bits 23..26, the prescaler
//! that picks the clock the counter runs on. `ra8_gpt_prescaler_t` in
//! ra8_gpt.h names six encodings and no others:
//!
//!   0  PCLKD / 1       the undivided peripheral clock
//!   1  PCLKD / 4
//!   2  PCLKD / 16
//!   3  PCLKD / 64
//!   4  PCLKD / 256
//!   5  PCLKD / 1024
//!
//! GTCR was interpreted for CST alone here, so the whole prescaler field was
//! a value the register stored and nothing read. `ra8_gpt_init` writes it on
//! every channel it brings up, and `ra8_gpt_three_phase_init` writes the same
//! one to all three motor channels on purpose, so a channel a driver had
//! deliberately slowed to PCLKD/1024 overflowed exactly as often as an
//! undivided one and a period chosen against a divider was a thousand times
//! out. dev's board_periph_timer.c has the same hole.
//!
//! There is no absolute time in this model, so a divider cannot be a real
//! frequency. It is ORDERED instead, the way agt/clock.zig already treats
//! AGTMR1.TCK: the counts one chunk boundary stands for are scaled down by
//! the selected divider, so divide-by-1024 really is a thousand times slower
//! than undivided and a period that fits in one boundary at PCLKD takes many
//! at PCLKD/1024. That ordering is what an image comparing two channels can
//! see.
//!
//! A DIVIDED STEP STAYS ODD. gpt.zig picks an odd advance per boundary so it
//! is coprime to the 2^16 and 2^32 saw periods the drivers use; an even one
//! divides those periods evenly, GTCNT then visits a handful of values, and a
//! demo sampling on a power-of-two cadence reads the same count every time
//! and calls the timer wedged. Dividing an odd step by four makes it even
//! again, so the divided step is nudged back up to odd. The ordering between
//! dividers survives: 16385, 4097, 1025, 257, 65, 17.
//!
//! NOT MODELLED, AND NOT GUESSED: the TPCS encodings neither the header nor
//! the driver names. TPCS is four bits wide and only six of its sixteen
//! values are named here, and on the part the rest reach the GTETRG event
//! inputs rather than a divided PCLKD. An unnamed encoding counts undivided
//! rather than being given an invented divisor, and `name()` says it is
//! unknown so the run does not claim to have recognised it. MD, the counter
//! mode, is still not modelled: every channel counts up in saw mode.

const std = @import("std");

/// The GTCR fields (ra8_gpt.c, HUM Ch 22.2.x p 904..906).
pub const field = struct {
    pub const cst: u32 = 0x0000_0001;
    pub const md: u32 = 0x000F_0000;
    pub const tpcs: u32 = 0x0780_0000;
};

/// The TPCS encodings ra8_gpt.h names, already shifted into place.
pub const Source = enum(u32) {
    pclkd = 0x0000_0000,
    pclkd_div4 = 0x0080_0000,
    pclkd_div16 = 0x0100_0000,
    pclkd_div64 = 0x0180_0000,
    pclkd_div256 = 0x0200_0000,
    pclkd_div1024 = 0x0280_0000,
    _,

    /// How many source edges one modelled count stands for. An encoding
    /// nobody named counts undivided rather than by an invented number.
    pub fn divider(self: Source) u32 {
        return switch (self) {
            .pclkd_div4 => 4,
            .pclkd_div16 => 16,
            .pclkd_div64 => 64,
            .pclkd_div256 => 256,
            .pclkd_div1024 => 1024,
            else => 1,
        };
    }

    pub fn name(self: Source) []const u8 {
        return switch (self) {
            .pclkd => "PCLKD",
            .pclkd_div4 => "PCLKD/4",
            .pclkd_div16 => "PCLKD/16",
            .pclkd_div64 => "PCLKD/64",
            .pclkd_div256 => "PCLKD/256",
            .pclkd_div1024 => "PCLKD/1024",
            _ => "unknown count source",
        };
    }
};

/// The source GTCR selects.
pub fn sourceOf(cr: u32) Source {
    return @fromBackingInt(@intCast(cr & field.tpcs));
}

/// The counts one chunk boundary stands for at this source. The result is
/// odd, for the coprimality reason in the header, and a divider never scales
/// the step away to nothing: the slowest channel still moves.
pub fn step(per_boundary: u32, source: Source) u32 {
    const divided = per_boundary / source.divider();
    return @max(1, divided) | 1;
}

/// When a channel's next due time on the virtual queue lives, reached as
/// `gpt_clock.sched` (RA8EMU-179, slice RA8EMU-513).
pub const sched = @import("sched.zig");

/// Virtual ns until a saw or one-shot count at `cnt` passes `period`, on
/// `source` with PCLKD at `pclkd_hz`. The count wraps on the edge after it
/// reaches the period, so that is `period - cnt + 1` counts, each one
/// `divider` PCLKD edges, rounded up so the wrap is never reported early. A
/// count already past the period wraps on its next edge. A zero clock never
/// gets there.
pub fn overflowInNs(cnt: u32, period: u32, source: Source, pclkd_hz: u64) ?u64 {
    if (pclkd_hz == 0) return null;
    const counts: u128 = if (cnt <= period) @as(u128, period) - cnt + 1 else 1;
    const edges = counts * source.divider();
    const ns = (edges * 1_000_000_000 + pclkd_hz - 1) / pclkd_hz;
    return @intCast(@min(ns, std.math.maxInt(u64)));
}
