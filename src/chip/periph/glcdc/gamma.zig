//! GLCDC gamma correction: the three per-channel piecewise-linear blocks.
//!
//! Each colour channel gets its own 64-byte block (GAM[0]=R at +0x1300,
//! GAM[1]=G at +0x1340, GAM[2]=B at +0x1380, HUM Ch 63 p 3789-3793). A block
//! is eight LUT registers packing two 11-bit gains each, and eight AREA
//! registers packing two 10-bit thresholds each: sixteen segments over the
//! 10-bit output pipeline, each with its own slope. The global switch
//! GAMSW.GAMON lives in the OUT block, not here.
//!
//! The in-tree driver (ra8_glcdc_gamma.c) writes all sixteen gains and all
//! sixteen thresholds through this packing, then flips GAMON. dev snoops
//! none of it: a panel corrected for its own transfer curve came out of that
//! tree with the uncorrected colours in the witness.
const std = @import("std");

/// Where the blocks sit and how big they are.
pub const geometry = struct {
    pub const channels: u32 = 3;
    pub const bases = [channels]u32{ 0x1300, 0x1340, 0x1380 };
    /// sizeof(ra8_glcdc_gam_t): LUT[8] then AREA[8].
    pub const block_bytes: u32 = 64;
    pub const lut_base: u32 = 0x00;
    pub const area_base: u32 = 0x20;
    /// Registers per table, and the entries they pack.
    pub const registers: u32 = 8;
    pub const entries: u32 = 16;
};

/// The packing inside a LUT or AREA register, and the pipeline it feeds.
pub const field = struct {
    pub const gain_shift: u5 = 16;
    pub const gain_mask: u32 = 0x7FF;
    pub const threshold_shift: u5 = 16;
    pub const threshold_mask: u32 = 0x3FF;
    /// An 11-bit gain of 1024 is unity, so a ramp of these is identity.
    pub const unity: u32 = 1024;
    /// The correction runs in 10 bits; the panel takes 8.
    pub const full: u32 = 1023;
    pub const depth_shift: u3 = 2;
};

/// Which table inside a channel block an offset names.
pub const Table = enum { lut, area };

/// A register inside one channel's block.
pub const Slot = struct {
    channel: u8,
    table: Table,
    index: u8,
};

/// The slot an offset inside the GLCDC window names, or null when the
/// offset is outside all three gamma blocks.
pub fn slotOf(offset: u32) ?Slot {
    for (geometry.bases, 0..) |base, channel| {
        if (offset < base or offset >= base + geometry.block_bytes) continue;
        const local = offset - base;
        const table: Table = if (local < geometry.area_base) .lut else .area;
        const within = if (table == .lut) local else local - geometry.area_base;
        return .{
            .channel = @intCast(channel),
            .table = table,
            .index = @intCast(within / 4),
        };
    }
    return null;
}

/// One channel's correction curve.
pub const Channel = struct {
    /// Slope per segment, in 1/1024 units.
    gain: [geometry.entries]u16 = @splat(@intCast(field.unity)),
    /// The input value each segment ends at, in 10-bit space.
    threshold: [geometry.entries]u16 = defaultThresholds(),
    /// Whether the driver has written this block. An untouched channel
    /// passes its value through, so a GAMON set over an unprogrammed block
    /// does not black the panel out.
    programmed: bool = false,
    /// Writes taken, so a half-programmed block is visible in the report.
    writes: u32 = 0,

    /// Take one LUT or AREA register. Both halves land, because the driver
    /// writes the pair in one store.
    pub fn latch(self: *Channel, slot: Slot, value: u32) void {
        const high: u8 = @intCast(slot.index * 2);
        const low: u8 = high + 1;
        switch (slot.table) {
            .lut => {
                self.gain[high] = @intCast(value >> field.gain_shift & field.gain_mask);
                self.gain[low] = @intCast(value & field.gain_mask);
            },
            .area => {
                self.threshold[high] =
                    @intCast(value >> field.threshold_shift & field.threshold_mask);
                self.threshold[low] = @intCast(value & field.threshold_mask);
            },
        }
        self.programmed = true;
        self.writes +%= 1;
    }

    /// Correct one 10-bit sample. Walks the segments, accumulating each
    /// one's rise, and interpolates inside the segment the sample lands in.
    pub fn apply(self: *const Channel, value: u32) u32 {
        if (!self.programmed) return value;
        var output: u32 = 0;
        var start: u32 = 0;
        for (0..geometry.entries) |index| {
            const gain = self.gain[index];
            const end: u32 = if (index + 1 == geometry.entries)
                field.full + 1
            else
                self.threshold[index];
            if (end <= start) continue;
            if (value < end) return clamp(output + rise(value - start, gain));
            output += rise(end - start, gain);
            start = end;
        }
        return clamp(output);
    }

    /// Whether this curve leaves every sample where it found it.
    pub fn identity(self: *const Channel) bool {
        if (!self.programmed) return true;
        for (self.gain) |gain| {
            if (gain != field.unity) return false;
        }
        return true;
    }
};

/// A segment's rise over a span of input, at its own slope.
fn rise(span: u32, gain: u16) u32 {
    return span * gain / field.unity;
}

fn clamp(value: u32) u32 {
    return @min(value, field.full);
}

/// An even ramp across the 10-bit range, which is what a driver that fills
/// the AREA table with equal steps writes.
fn defaultThresholds() [geometry.entries]u16 {
    var table: [geometry.entries]u16 = undefined;
    for (&table, 0..) |*entry, index| {
        entry.* = @intCast((index + 1) * (field.full + 1) / geometry.entries);
    }
    return table;
}
