//! `--gif-out PATH`: the GIF encoder (ra8_render) over a file this opens.
//! The encoder only produces bytes; this owns the file, syncs it once the
//! last frame is written and closes it.
const std = @import("std");
const gif = @import("ra8_render").gif;

pub const Writer = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    file: std.Io.File,
    /// Heap-held so the interface stays put while the Writer moves.
    sink: *std.Io.File.Writer,
    buffer: []u8,
    encoder: gif.Encoder,

    /// Creates `path`, or truncates it, and writes the GIF header. A frame
    /// size the format cannot hold is refused before the file is touched.
    pub fn init(allocator: std.mem.Allocator, io: std.Io, path: []const u8, width: u32, height: u32) !Writer {
        if (!gif.fits(width, height)) return error.BadShape;
        const file = try std.Io.Dir.cwd().createFile(io, path, .{ .truncate = true });
        errdefer file.close(io);
        const buffer = try allocator.alloc(u8, 8192);
        errdefer allocator.free(buffer);
        const sink = try allocator.create(std.Io.File.Writer);
        errdefer allocator.destroy(sink);
        sink.* = file.writerStreaming(io, buffer);
        const encoder = try gif.Encoder.init(allocator, &sink.interface, width, height);
        return .{ .allocator = allocator, .io = io, .file = file, .sink = sink, .buffer = buffer, .encoder = encoder };
    }

    pub fn record(self: *Writer, width: u32, height: u32, pixels: []const u32, when: u64) !void {
        return self.encoder.record(width, height, pixels, when);
    }

    /// Writes what is pending and the trailer, then syncs the file.
    pub fn finish(self: *Writer) !void {
        try self.encoder.finish();
        try self.file.sync(self.io);
    }

    pub fn deinit(self: *Writer) void {
        self.encoder.deinit();
        self.allocator.destroy(self.sink);
        self.allocator.free(self.buffer);
        self.file.close(self.io);
    }
};
