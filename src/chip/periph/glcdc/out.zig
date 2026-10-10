//! The GLCDC output stage: what the composited panel looks like on the pins.
//!
//! A pixel leaving the mixer is not what the panel receives. The output
//! block corrects it through the gamma curves, scales it by CONTRAST,
//! offsets it by BRIGHT, then narrows it to the bus the panel is wired for:
//! RGB888, RGB666 or RGB565 (OUT_SET.FORMAT, HUM Ch 63 p 3744). Dropping
//! those low bits is the part a driver notices, which is why PDTHA.SEL can
//! dither instead of truncating.
//!
//! dev models none of this window: it hashes the composite and calls it the
//! panel, so an app that dithers down to a 16-bit panel and one that drives
//! a full 24-bit bus produce the same witness.
//!
//! OUT_SET, OUT_PDTHA, BRIGHT1/2 and CONTRAST are shadow registers: they
//! reach the output stage when OUT_VLATCH.VEN is written, which is step 4 of
//! the driver's own bring-up. A stage programmed and never latched still
//! shows the old picture, and that is counted here rather than smoothed over.
const gam = @import("gamma.zig");
/// The frame boundary a viewer installs on the stage (RA8EMU-573).
pub const vsync = @import("vsync.zig");

/// Register byte offsets inside the GLCDC window.
pub const off = struct {
    pub const vlatch: u32 = 0x13C0;
    pub const set: u32 = 0x13C4;
    pub const bright1: u32 = 0x13C8;
    pub const bright2: u32 = 0x13CC;
    pub const contrast: u32 = 0x13D0;
    pub const pdtha: u32 = 0x13D4;
    pub const gamsw: u32 = 0x13D8;
    pub const clkphase: u32 = 0x13E4;
};

/// Field positions the driver writes through.
pub const field = struct {
    /// VLATCH.VEN: commit the shadows.
    pub const ven: u32 = 0x1;
    /// OUT_SET.FORMAT [13:12].
    pub const format_shift: u5 = 12;
    pub const format_mask: u32 = 0x3;
    /// PDTHA.SEL [9:8] and PDTHA.FORM [17:16].
    pub const dither_shift: u5 = 8;
    pub const dither_mask: u32 = 0x3;
    pub const dither_format_shift: u5 = 16;
    /// PDTHA pattern cells PA/PB/PC/PD, two bits each from bit 0.
    pub const pattern_mask: u32 = 0x3;
    pub const pattern_step: u5 = 2;
    /// GAMSW.GAMON.
    pub const gamon: u32 = 0x1;
    /// One channel's brightness offset or contrast gain.
    pub const channel_mask: u32 = 0x3FF;
    pub const green_shift: u5 = 16;
    pub const blue_shift: u5 = 8;
    /// The driver's identity settings: mid-scale offset, unity gain.
    pub const bright_mid: u32 = 512;
    pub const contrast_unity: u32 = 128;
};

/// OUT_SET.FORMAT: how wide the panel bus is.
pub const Format = enum(u2) {
    rgb888 = 0,
    rgb666 = 1,
    rgb565 = 2,
    reserved = 3,

    /// Bits the panel keeps, red, green, blue.
    pub fn depth(self: Format) [3]u4 {
        return switch (self) {
            .rgb888, .reserved => .{ 8, 8, 8 },
            .rgb666 => .{ 6, 6, 6 },
            .rgb565 => .{ 5, 6, 5 },
        };
    }

    /// Whether any bit is dropped on the way out.
    pub fn narrows(self: Format) bool {
        for (self.depth()) |bits| {
            if (bits < 8) return true;
        }
        return false;
    }
};

/// PDTHA.SEL: what happens to the bits the bus cannot carry.
pub const Dither = enum(u2) {
    off = 0,
    reserved = 1,
    truncate = 2,
    pattern = 3,
};

/// The four shadowed registers, as the stage reads them.
pub const Shadow = struct {
    set: u32 = 0,
    bright1: u32 = field.bright_mid,
    bright2: u32 = field.bright_mid << field.green_shift | field.bright_mid,
    contrast: u32 = field.contrast_unity << field.green_shift |
        field.contrast_unity << field.blue_shift | field.contrast_unity,
    pdtha: u32 = 0,

    pub fn format(self: Shadow) Format {
        return @fromBackingInt(@intCast(self.set >> field.format_shift & field.format_mask));
    }

    pub fn dither(self: Shadow) Dither {
        return @fromBackingInt(@intCast(self.pdtha >> field.dither_shift & field.dither_mask));
    }

    /// The 2x2 cell added before the bits are dropped, in output steps.
    pub fn cell(self: Shadow, column: u32, row: u32) u32 {
        const index: u5 = @intCast((row & 1) * 2 + (column & 1));
        return self.pdtha >> index * field.pattern_step & field.pattern_mask;
    }

    /// BRIGHT offsets, red green blue, signed around mid-scale.
    pub fn brightness(self: Shadow) [3]i32 {
        const mid: i32 = @intCast(field.bright_mid);
        return .{
            @as(i32, @intCast(self.bright2 & field.channel_mask)) - mid,
            @as(i32, @intCast(self.bright1 & field.channel_mask)) - mid,
            @as(i32, @intCast(self.bright2 >> field.green_shift & field.channel_mask)) - mid,
        };
    }

    /// CONTRAST gains, red green blue, in 1/128 units.
    pub fn contrasts(self: Shadow) [3]u32 {
        return .{
            self.contrast & 0xFF,
            self.contrast >> field.green_shift & 0xFF,
            self.contrast >> field.blue_shift & 0xFF,
        };
    }
};

/// A host-side copy of what leaves the stage, row-major, for the board view
/// (RA8EMU-73). Null unless a frame is being saved, so other runs are unchanged.
pub const Capture = struct {
    pixels: []u32,
    width: u32,
    height: u32,

    /// Keep one pixel; anything outside the buffer is dropped.
    pub fn put(self: Capture, column: u32, row: u32, colour: u32) void {
        if (column >= self.width or row >= self.height) return;
        self.pixels[@as(usize, row) * self.width + column] = colour;
    }
};

/// The output stage: the shadows, what was latched into the live copy, the
/// gamma curves, and what the pixels did on the way through.
pub const Stage = struct {
    shadow: Shadow = .{},
    live: Shadow = .{},
    gamma: [gam.geometry.channels]gam.Channel = @splat(.{}),
    /// GAMSW.GAMON, which is not shadowed.
    gamma_on: bool = false,
    /// Writes into the window.
    writes: u32 = 0,
    /// VLATCH.VEN commits.
    commits: u32 = 0,
    /// Pixels that went through the stage.
    pixels: u32 = 0,
    /// Pixels a gamma curve moved.
    corrected: u32 = 0,
    /// Pixels the dither pattern moved.
    dithered: u32 = 0,
    /// Pixels a bit was dropped from on the way to the bus.
    narrowed: u32 = 0,
    /// Pixels brightness or contrast pinned at an end of the range.
    clipped: u32 = 0,
    /// Where the pixels are copied while a frame is saved (RA8EMU-73).
    capture: ?Capture = null,
    /// Set only while a viewer wants every frame scanned during the run.
    vsync: ?vsync.Vsync = null,

    pub fn quiet(self: *const Stage) bool {
        return self.writes == 0 and self.pixels == 0;
    }

    /// Whether a shadow was written that VLATCH has not committed. This is
    /// the honest answer to "why is the panel still the old colour".
    pub fn pending(self: *const Stage) bool {
        const a = self.shadow;
        const b = self.live;
        return a.set != b.set or a.bright1 != b.bright1 or a.bright2 != b.bright2 or
            a.contrast != b.contrast or a.pdtha != b.pdtha;
    }

    /// Take a write. True when the offset belonged to this stage.
    pub fn latch(self: *Stage, offset: u32, value: u32) bool {
        if (gam.slotOf(offset)) |slot| {
            self.gamma[slot.channel].latch(slot, value);
            self.writes +%= 1;
            return true;
        }
        switch (offset) {
            off.vlatch => if (value & field.ven != 0) self.commit(),
            off.set => self.shadow.set = value,
            off.bright1 => self.shadow.bright1 = value,
            off.bright2 => self.shadow.bright2 = value,
            off.contrast => self.shadow.contrast = value,
            off.pdtha => self.shadow.pdtha = value,
            off.gamsw => self.gamma_on = value & field.gamon != 0,
            off.clkphase => {},
            else => return false,
        }
        self.writes +%= 1;
        return true;
    }

    /// VLATCH.VEN: the shadows become what the panel is driven from.
    pub fn commit(self: *Stage) void {
        self.live = self.shadow;
        self.commits +%= 1;
    }

    /// Put one composited ARGB8888 pixel on the bus.
    pub fn apply(self: *Stage, colour: u32, column: u32, row: u32) u32 {
        self.pixels +%= 1;
        const depth = self.live.format().depth();
        const bright = self.live.brightness();
        const gains = self.live.contrasts();
        var result: u32 = colour & 0xFF00_0000;
        var moved = false;
        var dropped = false;
        var patterned = false;
        for (0..3) |index| {
            const shift: u5 = @intCast((2 - index) * 8);
            const source: u32 = colour >> shift & 0xFF;
            var sample = source << gam.field.depth_shift;
            if (self.gamma_on) sample = self.gamma[index].apply(sample);
            const scaled = self.scale(sample, gains[index], bright[index], &moved);
            const onto_bus = self.narrow(scaled, depth[index], column, row, &patterned);
            if (onto_bus != source) dropped = true;
            result |= onto_bus << shift;
        }
        if (self.gamma_on and !self.identity()) self.corrected +%= 1;
        if (moved) self.clipped +%= 1;
        if (patterned) self.dithered +%= 1;
        if (dropped and self.live.format().narrows()) self.narrowed +%= 1;
        if (self.capture) |grab| grab.put(column, row, result);
        return result;
    }

    /// Contrast then brightness, in the 10-bit pipeline, back to 8 bits.
    fn scale(self: *Stage, sample: u32, gain: u32, offset: i32, moved: *bool) u32 {
        _ = self;
        const wide: i32 = @intCast(sample * gain / field.contrast_unity);
        const shifted = wide + offset;
        if (shifted < 0 or shifted > @as(i32, @intCast(gam.field.full))) moved.* = true;
        const held: u32 = @intCast(@min(@max(shifted, 0), @as(i32, @intCast(gam.field.full))));
        return held >> gam.field.depth_shift;
    }

    /// Drop the bits the panel bus cannot carry, dithering first when the
    /// driver asked for a pattern.
    fn narrow(
        self: *Stage,
        sample: u32,
        bits: u4,
        column: u32,
        row: u32,
        patterned: *bool,
    ) u32 {
        if (bits >= 8) return sample;
        const step: u32 = @as(u32, 1) << @intCast(8 - @as(u32, bits));
        var value = sample;
        if (self.live.dither() == .pattern) {
            const added = self.live.cell(column, row) * step / 4;
            if (added != 0) patterned.* = true;
            value = @min(value + added, 0xFF);
        }
        return value / step * step;
    }

    /// Whether every gamma curve leaves its samples alone.
    fn identity(self: *const Stage) bool {
        for (self.gamma) |channel| {
            if (!channel.identity()) return false;
        }
        return true;
    }
};

/// Whether an offset in the GLCDC window belongs to the output stage.
pub fn owns(offset: u32) bool {
    if (gam.slotOf(offset) != null) return true;
    return switch (offset) {
        off.vlatch, off.set, off.bright1, off.bright2 => true,
        off.contrast, off.pdtha, off.gamsw, off.clkphase => true,
        else => false,
    };
}
