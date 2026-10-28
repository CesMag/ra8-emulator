//! The body of a `camera_frame` boundary record: one frame the CEU captured,
//! as the bytes the firmware's buffer got, with the geometry the CEU asked
//! for and the sensor's pixel format at that capture.
//!
//! Layout, little-endian:
//!   u32 width    bytes per line
//!   u32 lines
//!   u8  format
//!   u8  flags    bit 0: the payload is zlib-deflated
//!   u32 raw_len  the pixel bytes after inflating (width * lines)
//!   u32 len      the payload's bytes
//!   payload
//!   u32 crc      CRC-32C over every byte above
//!
//! A reader that finds the CRC wrong or a length that lies refuses the
//! record: replay feeding the guest altered pixels would diverge silently.
const std = @import("std");
const flate = std.compress.flate;
const Crc32c = std.hash.crc.@"CRC-32/ISCSI";

pub const Error = error{ Truncated, BadValue, BadCrc };

/// The OV5640 output format the capture ran in.
pub const Format = enum(u8) { yuv422 = 0, rgb565 = 1, _ };

pub const Flags = struct {
    pub const deflated: u8 = 1;
    pub const known: u8 = deflated;
};

/// What a frame is, apart from its pixels.
pub const Meta = struct {
    width: u32,
    lines: u32,
    format: Format,
};

/// Frames at or under this size are stored as they are.
pub const compress_over: usize = 1024;

const fixed_len: usize = 4 + 4 + 1 + 1 + 4 + 4;
const crc_len: usize = 4;

/// Appends the record for `pixels` (width * lines bytes) to `writer`. The
/// pixels are deflated when that makes the record smaller.
pub fn encode(allocator: std.mem.Allocator, writer: *std.Io.Writer, meta: Meta, pixels: []const u8) !void {
    if (@as(u64, meta.width) * meta.lines != pixels.len) return Error.BadValue;
    var deflated: std.Io.Writer.Allocating = try .initCapacity(allocator, 256);
    defer deflated.deinit();
    var payload: []const u8 = pixels;
    var flags: u8 = 0;
    if (pixels.len > compress_over) {
        const window = try allocator.alloc(u8, flate.max_window_len);
        defer allocator.free(window);
        var deflater = try flate.Compress.init(&deflated.writer, window, .zlib, .default);
        try deflater.writer.writeAll(pixels);
        try deflater.finish();
        if (deflated.written().len < pixels.len) {
            payload = deflated.written();
            flags = Flags.deflated;
        }
    }
    var head: [fixed_len]u8 = undefined;
    std.mem.writeInt(u32, head[0..4], meta.width, .little);
    std.mem.writeInt(u32, head[4..8], meta.lines, .little);
    head[8] = @backingInt(meta.format);
    head[9] = flags;
    std.mem.writeInt(u32, head[10..14], @intCast(pixels.len), .little);
    std.mem.writeInt(u32, head[14..18], @intCast(payload.len), .little);
    var crc = Crc32c.init();
    crc.update(&head);
    crc.update(payload);
    try writer.writeAll(&head);
    try writer.writeAll(payload);
    try writer.writeInt(u32, crc.final(), .little);
}

/// Checks `body` and returns its geometry; the pixels are appended to `out`
/// (cleared first), inflated when the record carries them deflated.
pub fn decode(allocator: std.mem.Allocator, body: []const u8, out: *std.ArrayList(u8)) !Meta {
    if (body.len < fixed_len + crc_len) return Error.Truncated;
    const payload_len = std.mem.readInt(u32, body[14..18], .little);
    if (body.len != fixed_len + @as(usize, payload_len) + crc_len) return Error.Truncated;
    const covered = body[0 .. body.len - crc_len];
    if (Crc32c.hash(covered) != std.mem.readInt(u32, body[body.len - crc_len ..][0..4], .little)) return Error.BadCrc;
    const meta: Meta = .{
        .width = std.mem.readInt(u32, body[0..4], .little),
        .lines = std.mem.readInt(u32, body[4..8], .little),
        .format = @fromBackingInt(@intCast(body[8])),
    };
    const flags = body[9];
    const raw_len = std.mem.readInt(u32, body[10..14], .little);
    if (flags & ~Flags.known != 0) return Error.BadValue;
    if (@as(u64, meta.width) * meta.lines != raw_len) return Error.BadValue;
    const payload = body[fixed_len..][0..payload_len];
    out.clearRetainingCapacity();
    try out.resize(allocator, raw_len);
    if (flags & Flags.deflated == 0) {
        if (payload.len != raw_len) return Error.BadValue;
        @memcpy(out.items, payload);
        return meta;
    }
    const window = try allocator.alloc(u8, flate.max_window_len);
    defer allocator.free(window);
    var input: std.Io.Reader = .fixed(payload);
    var inflater: flate.Decompress = .init(&input, .zlib, window);
    inflater.reader.readSliceAll(out.items) catch return Error.BadValue;
    return meta;
}
