//! Scanning the panel: reading the framebuffer the display controller was
//! pointed at and saying what is actually in it.
//!
//! dev stops one step short of this. Its GLCDC block is registered
//! `observe = true`, snoops eleven register offsets, recovers a descriptor,
//! and folds an FNV-1a-32 over the raw framebuffer bytes at report time. Two
//! things follow from hashing bytes instead of pixels. A CLUT-mode layer is
//! hashed as index bytes, so the palette a driver spent its init writing is
//! not in the witness at all and a run with no palette hashes the same as a
//! run with one. And the hash is over the fetch, not over what reaches the
//! panel: a layer whose framebuffer runs off the end of its RAM window, or
//! one with the output stage off, hashes like any other.
//!
//! Here the scan decodes each pixel to ARGB8888 through the format and the
//! layer's palette, hashes the decoded colours, and refuses the cases that
//! are not a picture.
const std = @import("std");
const Guest = @import("../../core/cpu/memory/guest.zig").Guest;
const clut = @import("clut.zig");

/// FNV-1a-32, the same basis and prime dev's framebuffer hash uses, so a
/// witness from either tree is comparable on the formats that carry colour
/// directly. A CLUT-mode witness is deliberately not comparable: dev hashes
/// the index, this hashes the colour it looks up.
pub const fnv = struct {
    pub const offset: u32 = 2166136261;
    pub const prime: u32 = 16777619;
};

/// Bounds on one scan (the whole point of a bound here is that a
/// half-programmed descriptor asks for a gigapixel panel).
pub const limits = struct {
    /// Bytes read from guest memory in one go.
    pub const chunk: u32 = 4096;
    /// Largest framebuffer this will walk, 8 MiB, as dev caps it.
    pub const max_bytes: u32 = 0x80_0000;
};

/// Why a scan produced no picture.
pub const Refusal = enum {
    /// Neither layer is fetching from something that looks like a framebuffer.
    no_layer,
    /// The output stage is off: the fetch happens, the panel stays dark.
    output_off,
    /// The framebuffer runs past the end of the RAM window it starts in.
    off_ram,
    /// A CLUT format over a palette plane nobody filled.
    no_palette,
    /// Larger than this will walk.
    too_big,
    /// Guest memory would not give the bytes up.
    fault,
    /// The pixel clock was never started: SYSCNT.PANEL_CLK.CLKEN is clear,
    /// so the controller scans nothing however well its layers are set up.
    unclocked,
};

/// What one scan saw.
pub const Picture = struct {
    /// FNV-1a-32 over the decoded ARGB8888 pixels, row by row, padding skipped.
    hash: u32,
    /// Pixels decoded.
    pixels: u32,
    /// Pixels whose alpha came out fully transparent. A panel of these is
    /// a framebuffer that was cleared and never drawn into, which reads very
    /// differently from a blank hash.
    blank: u32,
    /// Distinct colours seen, up to the sample bound below. One is a flat
    /// fill; the e-reader and display examples land well above it.
    colours: u32,
};

/// How many distinct colours the scan will track before it stops counting.
/// A witness only needs to tell a flat fill from a drawing.
pub const colour_sample: u32 = 64;

/// The scan itself: a small state machine over one framebuffer, kept apart
/// from the block so the block stays about registers.
pub const Scanner = struct {
    /// Scans that produced a picture.
    scans: u32 = 0,
    /// Pixels decoded across every scan.
    pixels: u32 = 0,
    /// Per-reason refusal counts, indexed by Refusal.
    refused: [@typeInfo(Refusal).@"enum".field_names.len]u32 = @splat(0),
    /// The last picture, which is what the report prints.
    last: ?Picture = null,
    /// Why the last scan refused, when it did.
    last_refusal: ?Refusal = null,

    pub fn quiet(self: *const Scanner) bool {
        return self.scans == 0 and self.last_refusal == null;
    }

    fn refuse(self: *Scanner, why: Refusal) ?Picture {
        self.refused[@backingInt(why)] += 1;
        self.last_refusal = why;
        return null;
    }

    /// Record a refusal the caller worked out for itself, so every reason
    /// the panel produced no picture is counted in one place.
    pub fn refuseWith(self: *Scanner, why: Refusal) ?Picture {
        return self.refuse(why);
    }

    /// Note a picture the caller folded, so the report finds it where a
    /// single-framebuffer scan would have left it.
    pub fn record(self: *Scanner, picture: Picture) ?Picture {
        self.scans += 1;
        self.pixels += picture.pixels;
        self.last_refusal = null;
        self.last = picture;
        return self.last;
    }

    pub fn count(self: *const Scanner, why: Refusal) u32 {
        return self.refused[@backingInt(why)];
    }

    /// No layer is fetching from anything that looks like a framebuffer.
    pub fn refuseNoLayer(self: *Scanner) ?Picture {
        return self.refuse(.no_layer);
    }

    /// A layer is fetching and BG_EN.EN is clear, so the fetch happens and
    /// the panel stays dark. dev reports this as "idle" beside a hash of the
    /// framebuffer, which reads as a picture nobody can see.
    pub fn refuseOutputOff(self: *Scanner) ?Picture {
        return self.refuse(.output_off);
    }

    /// The pixel clock was never started, so no frame leaves the
    /// controller at all. Everything upstream of the clock can be perfectly
    /// programmed and the glass still stays dark.
    pub fn refuseUnclocked(self: *Scanner) ?Picture {
        return self.refuse(.unclocked);
    }

    /// Walk a framebuffer and decode it. `read` is how bytes come out of
    /// guest memory, `decode` turns a fetched pixel into ARGB8888.
    pub fn run(
        self: *Scanner,
        memory: Guest,
        shape: Shape,
        palette: *const clut.Palette,
    ) ?Picture {
        if (validate(shape, palette)) |why| return self.refuse(why);

        var state = Fold{};
        var line: [limits.chunk]u8 = undefined;
        var row: u32 = 0;
        while (row < shape.height) : (row += 1) {
            const wanted = shape.lineBytes();
            if (wanted > line.len) return self.refuse(.too_big);
            memory.read(shape.base + row * shape.stride, line[0..wanted]) catch {
                return self.refuse(.fault);
            };
            state.row(line[0..wanted], shape, palette);
        }
        self.scans += 1;
        self.pixels += state.pixels;
        self.last_refusal = null;
        self.last = state.picture();
        return self.last;
    }
};

/// What stops a framebuffer being readable at all: an empty palette under a
/// CLUT format, a span this will not walk, or a last line past the end of
/// the RAM window the base sits in. Null when it reads.
pub fn validate(shape: Shape, palette: *const clut.Palette) ?Refusal {
    if (shape.needsPalette() and !palette.programmed()) return .no_palette;
    const total = shape.bytes() orelse return .too_big;
    if (total > limits.max_bytes) return .too_big;
    const end = shape.window_end orelse return .off_ram;
    if (@as(u64, shape.base) + total > end) return .off_ram;
    return null;
}

/// What a scan needs to know about the framebuffer, lifted out of the
/// descriptor so this file does not have to know the register window.
pub const Shape = struct {
    base: u32,
    /// Pixels across, already corrected for sub-byte formats.
    width: u32,
    height: u32,
    /// Bytes between the start of one line and the next.
    stride: u32,
    /// Bits one pixel occupies in memory.
    bits: u32,
    /// How a fetched pixel becomes a colour.
    decode: *const fn (raw: u32, palette: *const clut.Palette) u32,
    /// Whether the format looks a colour up rather than carrying it.
    indexed: bool,
    /// End of the RAM window the base sits in, or null when it sits in none.
    window_end: ?u32,

    pub fn needsPalette(self: Shape) bool {
        return self.indexed;
    }

    /// Bytes a line of visible pixels occupies, which is not the stride: the
    /// stride may pad, and a sub-byte format packs several pixels per byte.
    pub fn lineBytes(self: Shape) u32 {
        return (self.width * self.bits + 7) / 8;
    }

    /// Bytes from the base to the end of the last line, or null on overflow.
    pub fn bytes(self: Shape) ?u32 {
        if (self.height == 0 or self.width == 0) return null;
        const span = @as(u64, self.stride) * (self.height - 1) + self.lineBytes();
        if (span > limits.max_bytes) return null;
        return @intCast(span);
    }
};

/// The running fold over the pixels that reach the panel. Public because
/// the mixer folds composited pixels through exactly this hash.
pub const Fold = struct {
    hash: u32 = fnv.offset,
    pixels: u32 = 0,
    blank: u32 = 0,
    seen: [colour_sample]u32 = @splat(0),
    colours: u32 = 0,

    pub fn row(self: *Fold, line: []const u8, shape: Shape, palette: *const clut.Palette) void {
        var column: u32 = 0;
        while (column < shape.width) : (column += 1) {
            const raw = fetch(line, column, shape.bits);
            self.pixel(shape.decode(raw, palette));
        }
    }

    pub fn pixel(self: *Fold, colour: u32) void {
        self.pixels += 1;
        if (colour >> 24 == 0) self.blank += 1;
        var byte: u32 = 0;
        while (byte < 4) : (byte += 1) {
            self.hash = (self.hash ^ (colour >> @intCast(byte * 8) & 0xFF)) *% fnv.prime;
        }
        self.note(colour);
    }

    fn note(self: *Fold, colour: u32) void {
        if (self.colours >= colour_sample) return;
        for (self.seen[0..self.colours]) |already| {
            if (already == colour) return;
        }
        self.seen[self.colours] = colour;
        self.colours += 1;
    }

    pub fn picture(self: *const Fold) Picture {
        return .{
            .hash = self.hash,
            .pixels = self.pixels,
            .blank = self.blank,
            .colours = self.colours,
        };
    }
};

/// One pixel out of a line, little-endian, for the one, two, four, eight,
/// sixteen and thirty-two bit widths the formats use. A sub-byte pixel is
/// taken from the high end of its byte first, which is the order the fetch
/// unit scans a line in.
pub fn fetch(line: []const u8, column: u32, bits: u32) u32 {
    if (bits >= 8) {
        const stride = bits / 8;
        const at = column * stride;
        if (at + stride > line.len) return 0;
        var value: u32 = 0;
        var byte: u32 = 0;
        while (byte < stride) : (byte += 1) {
            value |= @as(u32, line[at + byte]) << @intCast(byte * 8);
        }
        return value;
    }
    const per_byte = 8 / bits;
    const at = column / per_byte;
    if (at >= line.len) return 0;
    const slot = per_byte - 1 - column % per_byte;
    const mask = (@as(u32, 1) << @intCast(bits)) - 1;
    return line[at] >> @intCast(slot * bits) & mask;
}
