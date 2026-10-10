//! Tests for src/interfaces/render/png.zig.
const std = @import("std");
const cli_app = @import("cli_app");
const png = cli_app.report.png;

const Chunk = struct { kind: []const u8, data: []const u8 };

/// Split an encoded image into chunks, checking each CRC on the way.
fn chunks(bytes: []const u8, out: []Chunk) !usize {
    try std.testing.expectEqualSlices(u8, &png.signature, bytes[0..8]);
    var at: usize = 8;
    var count: usize = 0;
    while (at < bytes.len) : (count += 1) {
        const len = std.mem.readInt(u32, bytes[at..][0..4], .big);
        const kind = bytes[at + 4 ..][0..4];
        const data = bytes[at + 8 ..][0..len];
        var crc = std.hash.Crc32.init();
        crc.update(kind);
        crc.update(data);
        try std.testing.expectEqual(crc.final(), std.mem.readInt(u32, bytes[at + 8 + len ..][0..4], .big));
        out[count] = .{ .kind = kind, .data = data };
        at += 12 + len;
    }
    return count;
}

test "an RGBA image encodes as IHDR, IDAT and IEND with filtered rows inside" {
    const rgba = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 };
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try png.encode(std.testing.allocator, &out.writer, 2, 2, &rgba);
    var found: [4]Chunk = undefined;
    try std.testing.expectEqual(@as(usize, 3), try chunks(out.written(), &found));
    try std.testing.expectEqualStrings("IHDR", found[0].kind);
    try std.testing.expectEqualSlices(u8, &png.header(2, 2), found[0].data);
    try std.testing.expectEqualStrings("IDAT", found[1].kind);
    try std.testing.expectEqualStrings("IEND", found[2].kind);
    try std.testing.expectEqual(@as(usize, 0), found[2].data.len);

    var stream: std.Io.Reader = .fixed(found[1].data);
    var raw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer raw.deinit();
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var inflate: std.compress.flate.Decompress = .init(&stream, .zlib, &window);
    _ = try inflate.reader.streamRemaining(&raw.writer);
    const rows = [_]u8{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 0, 9, 10, 11, 12, 13, 14, 15, 16 };
    try std.testing.expectEqualSlices(u8, &rows, raw.written());
}

test "the header names 8-bit RGBA, deflate, no interlace, big-endian size" {
    const body = png.header(800, 480);
    try std.testing.expectEqual(@as(u32, 800), std.mem.readInt(u32, body[0..4], .big));
    try std.testing.expectEqual(@as(u32, 480), std.mem.readInt(u32, body[4..8], .big));
    try std.testing.expectEqualSlices(u8, &[_]u8{ 8, 6, 0, 0, 0 }, body[8..13]);
}

test "a wrong-sized buffer or an empty image is refused before anything is written" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    const three = [_]u8{ 0, 0, 0 };
    try std.testing.expectError(png.Error.BadShape, png.encode(std.testing.allocator, &out.writer, 1, 1, &three));
    try std.testing.expectError(png.Error.EmptyImage, png.encode(std.testing.allocator, &out.writer, 0, 1, &three));
    try std.testing.expectEqual(@as(usize, 0), out.written().len);
}

test "ARGB8888 words unpack to R, G, B, A bytes" {
    const pixels = [_]u32{ 0x80FF_4020, 0x0000_00FF };
    var out: [8]u8 = undefined;
    try png.fromArgb(&pixels, &out);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0xFF, 0x40, 0x20, 0x80, 0, 0, 0xFF, 0 }, &out);
    var short: [4]u8 = undefined;
    try std.testing.expectError(png.Error.BadShape, png.fromArgb(&pixels, &short));
}
