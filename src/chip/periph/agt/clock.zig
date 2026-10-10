//! The AGT count source: what the counter counts, and how fast.
//!
//! AGTMR1 carries two fields (ra8_agt_regs.h, HUM Ch 24.2.5 p 1168): TMOD in
//! the low three bits, and TCK[2:0] at bit 4 selecting the clock the counter
//! decrements on. The header names four encodings and no others:
//!
//!   000b  PCLKB                 the undivided peripheral clock
//!   001b  PCLKB / 8
//!   011b  PCLKB / 2
//!   101b  AGT0's underflow      AGT1 only, the cascade pair
//!
//! AGTMR1 was a shadow byte here. Firmware wrote it, read it back, and the
//! counter stepped at one rate whatever it said, so a channel a driver had
//! deliberately slowed down underflowed exactly as often as an undivided one
//! and a cascaded AGT1 counted on its own instead of on AGT0. dev's
//! board_periph_timer.c has the same hole and answers zero to the offset
//! besides, so AGTMR1 does not even read back on that tree.
//!
//! There is no absolute time in this model, so a divider cannot be a real
//! frequency. It is ORDERED instead, the way ulpt.zig already treats
//! ULPTMR2: the counts one chunk boundary stands for are scaled down by the
//! selected divider, so divide-by-eight really is eight times slower than
//! undivided and a period that fits in one boundary at PCLKB takes eight at
//! PCLKB/8. That ordering is what an image comparing two channels can see.
//!
//! NOT MODELLED, AND NOT GUESSED: the TCK encodings the header does not
//! name (010b, 100b, 110b, 111b, which on the part reach the subclock and
//! LOCO). An unnamed encoding counts undivided rather than being given an
//! invented divisor, and `name()` says it is unknown so the run does not
//! claim to have recognised it. AGTMR2's own CKS divider is not modelled
//! either: the header gives the register its offset and no field table, and
//! the driver writes it zero everywhere.

/// The AGTMR1 fields (ra8_agt_regs.h).
pub const field = struct {
    pub const tmod: u8 = 0x07;
    pub const tck: u8 = 0x70;
};

/// The cascade pair: AGT1's TCK = 101b counts AGT0's underflows
/// (ra8_agt_regs.h `ra8_agt_cascade_channels_t`, HUM Ch 24.2.5 p 1168 note 6).
pub const cascade = struct {
    pub const low: usize = 0;
    pub const high: usize = 1;
};

/// The TCK encodings the header names, already shifted into place.
pub const Source = enum(u8) {
    pclkb = 0x00,
    pclkb_div8 = 0x10,
    pclkb_div2 = 0x30,
    agt0_underflow = 0x50,
    _,

    /// How many source edges one modelled count stands for. An encoding
    /// nobody named counts undivided rather than by an invented number.
    pub fn divider(self: Source) u16 {
        return switch (self) {
            .pclkb_div2 => 2,
            .pclkb_div8 => 8,
            else => 1,
        };
    }

    /// Whether this channel counts another channel's underflow instead of a
    /// clock, which is the one source that does not step on its own.
    pub fn cascaded(self: Source) bool {
        return self == .agt0_underflow;
    }

    pub fn name(self: Source) []const u8 {
        return switch (self) {
            .pclkb => "PCLKB",
            .pclkb_div8 => "PCLKB/8",
            .pclkb_div2 => "PCLKB/2",
            .agt0_underflow => "AGT0 underflow",
            _ => "unknown count source",
        };
    }
};

/// The source AGTMR1 selects. Only channel 1 can cascade, so the encoding
/// reads as undivided PCLKB anywhere else rather than silently parking a
/// channel that would then never count at all.
pub fn sourceOf(mr1: u8, channel: usize) Source {
    const selected: Source = @fromBackingInt(@intCast(mr1 & field.tck));
    if (selected.cascaded() and channel != cascade.high) return .pclkb;
    return selected;
}

/// The counts one chunk boundary stands for at this source. A divider never
/// scales the step away to nothing: the slowest channel still moves.
pub fn step(per_boundary: u16, source: Source) u16 {
    if (source.cascaded()) return 0;
    const divided = per_boundary / source.divider();
    return @max(1, divided);
}

/// Virtual ns until a counter at `count` underflows, with PCLKB at
/// `pclkb_hz` (RA8EMU-512). Reaching zero is not the underflow, the borrow
/// on the next count is, so it takes count + 1 counts, each `divider()`
/// PCLKB edges long. Rounded up, so the event never lands before the count
/// would have. A cascaded channel has no clock of its own and a stopped
/// PCLKB never counts: both answer null.
pub fn underflowInNs(count: u16, source: Source, pclkb_hz: u64) ?u64 {
    if (source.cascaded() or pclkb_hz == 0) return null;
    const edges: u64 = (@as(u64, count) + 1) * source.divider();
    return (edges * ns_per_s + pclkb_hz - 1) / pclkb_hz;
}

const ns_per_s: u64 = 1_000_000_000;

/// When a channel's next underflow is due on the virtual time base.
pub const sched = @import("sched.zig");
