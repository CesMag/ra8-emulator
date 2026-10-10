//! Covers src/interfaces/render/gif.zig: the encoder round-trips frames with
//! their emulated delay, writes the same bytes for the same frames, and
//! refuses a size the format cannot hold.
const std = @import("std");
const cli_app = @import("cli_app");
const gif = cli_app.report.gif;
const lzw_decode = @import("gif_lzw_decode.zig");

const Decoded = struct {
    pixels: []u8,
    delay: u16,
};

fn decodeFrame(bytes: []const u8, allocator: std.mem.Allocator, requested: usize) !Decoded {
    try std.testing.expectEqualStrings("GIF89a", bytes[0..6]);
    var cursor: usize = 13 + 256 * 3 + 19;
    var frame: usize = 0;
    while (cursor < bytes.len and bytes[cursor] != 0x3B) {
        try std.testing.expectEqual(@as(u8, 0x21), bytes[cursor]);
        try std.testing.expectEqual(@as(u8, 0xF9), bytes[cursor + 1]);
        const delay = std.mem.readInt(u16, bytes[cursor + 4 ..][0..2], .little);
        cursor += 8;
        try std.testing.expectEqual(@as(u8, 0x2C), bytes[cursor]);
        cursor += 10;
        try std.testing.expectEqual(@as(u8, 8), bytes[cursor]);
        cursor += 1;

        var compressed: std.ArrayList(u8) = .empty;
        defer compressed.deinit(allocator);
        while (bytes[cursor] != 0) {
            const count = bytes[cursor];
            cursor += 1;
            try compressed.appendSlice(allocator, bytes[cursor .. cursor + count]);
            cursor += count;
        }
        cursor += 1;

        const decoded = try lzw_decode.decode(allocator, compressed.items);
        if (frame == requested) return .{ .pixels = decoded, .delay = delay };
        allocator.free(decoded);
        frame += 1;
    }
    return error.NoFrame;
}

/// Both frames through a fresh encoder, as the bytes it wrote.
fn encoded(out: *std.Io.Writer.Allocating, first: []const u32, second: []const u32) !void {
    var encoder = try gif.Encoder.init(std.testing.allocator, &out.writer, 2, 1);
    defer encoder.deinit();
    try encoder.record(2, 1, first, 1_000_000);
    try encoder.record(2, 1, second, 31_000_000);
    try encoder.finish();
}

test "GIF sequence round-trips both frames with emulated delay and deterministic bytes" {
    const first = [_]u32{ 0xFF11_2233, 0xFFAA_BBCC };
    const second = [_]u32{ 0xFFFF_0000, 0xFF00_FFFF };
    var out_a = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out_a.deinit();
    var out_b = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out_b.deinit();
    try encoded(&out_a, &first, &second);
    try encoded(&out_b, &first, &second);
    const a = out_a.written();
    try std.testing.expectEqualSlices(u8, a, out_b.written());
    try std.testing.expectEqual(@as(u8, 0x3B), a[a.len - 1]);
    const first_frame = try decodeFrame(a, std.testing.allocator, 0);
    defer std.testing.allocator.free(first_frame.pixels);
    const second_frame = try decodeFrame(a, std.testing.allocator, 1);
    defer std.testing.allocator.free(second_frame.pixels);
    try std.testing.expectEqualSlices(u8, &.{ 0x04, 0xB7 }, first_frame.pixels);
    try std.testing.expectEqualSlices(u8, &.{ 0xE0, 0x1F }, second_frame.pixels);
    try std.testing.expectEqual(@as(u16, 3), first_frame.delay);
    try std.testing.expectEqual(@as(u16, 3), second_frame.delay);
    try std.testing.expectError(error.NoFrame, decodeFrame(a, std.testing.allocator, 2));
}

test "a frame of another size, or a size the format cannot hold, is refused" {
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try std.testing.expect(gif.fits(1, 1));
    try std.testing.expect(gif.fits(65535, 65535));
    try std.testing.expect(!gif.fits(0, 4));
    try std.testing.expect(!gif.fits(65536, 4));
    try std.testing.expectError(error.BadShape, gif.Encoder.init(std.testing.allocator, &out.writer, 0, 4));
    try std.testing.expectEqual(@as(usize, 0), out.written().len);
    var encoder = try gif.Encoder.init(std.testing.allocator, &out.writer, 2, 1);
    defer encoder.deinit();
    try std.testing.expectError(error.BadShape, encoder.record(2, 2, &.{ 0, 0, 0, 0 }, 0));
}
