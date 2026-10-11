//! A small deterministic GIF89a encoder for sampled panel frames. It writes
//! to the writer it is given and opens nothing: whoever owns the file opens
//! it, and syncs and closes it after `finish`.
const std = @import("std");

pub const lzw = @import("lzw.zig");

/// Whether a frame of this size fits the format's 16-bit screen.
pub fn fits(width: u32, height: u32) bool {
    return width != 0 and height != 0 and width <= std.math.maxInt(u16) and height <= std.math.maxInt(u16);
}

pub const Encoder = struct {
    allocator: std.mem.Allocator,
    /// Where the bytes go. It must stay put for as long as the encoder lives.
    sink: *std.Io.Writer,
    width: u16,
    height: u16,
    pending: ?[]u32 = null,
    pending_when: u64 = 0,
    prior_delay: u16 = 10,
    wrote: usize = 0,

    /// Writes the header and the fixed palette to `sink`.
    pub fn init(allocator: std.mem.Allocator, sink: *std.Io.Writer, width: u32, height: u32) !Encoder {
        if (!fits(width, height)) return error.BadShape;
        var self: Encoder = .{ .allocator = allocator, .sink = sink, .width = @intCast(width), .height = @intCast(height) };
        try self.header();
        return self;
    }

    fn out(self: *Encoder) *std.Io.Writer {
        return self.sink;
    }

    fn word(self: *Encoder, value: u16) !void {
        try self.out().writeByte(@truncate(value));
        try self.out().writeByte(@truncate(value >> 8));
    }

    fn header(self: *Encoder) !void {
        try self.out().writeAll("GIF89a");
        try self.word(self.width);
        try self.word(self.height);
        try self.out().writeAll(&.{ 0xF7, 0, 0 });
        for (0..256) |index| {
            const i: u8 = @intCast(index);
            try self.out().writeAll(&.{
                @intCast(@as(u16, i >> 5) * 255 / 7),
                @intCast(@as(u16, (i >> 2) & 7) * 255 / 7),
                @intCast(@as(u16, i & 3) * 255 / 3),
            });
        }
        try self.out().writeAll(&.{ 0x21, 0xFF, 0x0B });
        try self.out().writeAll("NETSCAPE2.0");
        try self.out().writeAll(&.{ 3, 1, 0, 0, 0 });
    }

    fn delayFor(delta_ns: u64) u16 {
        const centiseconds = (delta_ns + 5_000_000) / 10_000_000;
        return @intCast(@min(@max(centiseconds, 1), std.math.maxInt(u16)));
    }

    /// The previous frame remains pending until the next timestamp establishes its delay.
    pub fn record(self: *Encoder, width: u32, height: u32, pixels: []const u32, when: u64) !void {
        if (width != self.width or height != self.height or pixels.len != @as(usize, width) * height) return error.BadShape;
        if (self.pending) |previous| {
            self.prior_delay = delayFor(when -| self.pending_when);
            try self.emit(previous, self.prior_delay);
            self.allocator.free(previous);
        }
        self.pending = try self.allocator.dupe(u32, pixels);
        self.pending_when = when;
    }

    fn emit(self: *Encoder, pixels: []const u32, delay: u16) !void {
        try self.out().writeAll(&.{ 0x21, 0xF9, 4, 0x04 });
        try self.word(delay);
        try self.out().writeAll(&.{ 0, 0, 0x2C });
        try self.word(0);
        try self.word(0);
        try self.word(self.width);
        try self.word(self.height);
        try self.out().writeByte(0);
        try self.out().writeByte(lzw.min_code_size);
        const indices = try self.allocator.alloc(u8, pixels.len);
        defer self.allocator.free(indices);
        for (pixels, indices) |pixel, *index| index.* = quantize(pixel);
        var compressed: std.ArrayList(u8) = .empty;
        defer compressed.deinit(self.allocator);
        try lzw.encode(self.allocator, indices, &compressed);
        var offset: usize = 0;
        while (offset < compressed.items.len) {
            const count = @min(255, compressed.items.len - offset);
            try self.out().writeByte(@intCast(count));
            try self.out().writeAll(compressed.items[offset .. offset + count]);
            offset += count;
        }
        try self.out().writeByte(0);
        self.wrote += 1;
    }

    /// RGB 3-3-2 index into the fixed palette written by `header`.
    fn quantize(pixel: u32) u8 {
        return @truncate((pixel >> 16 & 0xE0) | (pixel >> 11 & 0x1C) | (pixel >> 6 & 0x03));
    }

    /// Writes the last pending frame and the trailer, and flushes `sink`.
    pub fn finish(self: *Encoder) !void {
        if (self.pending) |pixels| {
            try self.emit(pixels, if (self.wrote == 0) 10 else self.prior_delay);
            self.allocator.free(pixels);
            self.pending = null;
        }
        try self.out().writeByte(0x3B);
        try self.out().flush();
    }

    pub fn deinit(self: *Encoder) void {
        if (self.pending) |pixels| self.allocator.free(pixels);
    }
};
