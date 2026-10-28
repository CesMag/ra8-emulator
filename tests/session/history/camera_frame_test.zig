//! Covers src/session/history/camera_frame.zig: a frame survives the codec
//! raw and deflated, and a flipped byte, a short body or a lying length is
//! refused rather than handed to the guest.
const std = @import("std");
const ra8 = @import("ra8");

const codec = ra8.session.history_camera_frame;

fn encoded(gpa: std.mem.Allocator, meta: codec.Meta, pixels: []const u8) !std.ArrayList(u8) {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    try codec.encode(gpa, &out.writer, meta, pixels);
    return out.toArrayList();
}

test "a small frame round-trips raw" {
    const gpa = std.testing.allocator;
    const pixels = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8 };
    var body = try encoded(gpa, .{ .width = 4, .lines = 2, .format = .rgb565 }, &pixels);
    defer body.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), body.items[9]);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    const meta = try codec.decode(gpa, body.items, &out);
    try std.testing.expectEqual(@as(u32, 4), meta.width);
    try std.testing.expectEqual(@as(u32, 2), meta.lines);
    try std.testing.expectEqual(codec.Format.rgb565, meta.format);
    try std.testing.expectEqualSlices(u8, &pixels, out.items);
}

test "a large flat frame is deflated and round-trips" {
    const gpa = std.testing.allocator;
    var pixels: [4096]u8 = undefined;
    for (&pixels, 0..) |*byte, i| byte.* = @truncate(i / 64);
    var body = try encoded(gpa, .{ .width = 64, .lines = 64, .format = .yuv422 }, &pixels);
    defer body.deinit(gpa);
    try std.testing.expectEqual(codec.Flags.deflated, body.items[9]);
    try std.testing.expect(body.items.len < pixels.len);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    const meta = try codec.decode(gpa, body.items, &out);
    try std.testing.expectEqual(codec.Format.yuv422, meta.format);
    try std.testing.expectEqualSlices(u8, &pixels, out.items);
}

test "a corrupt byte fails the CRC, in either encoding" {
    const gpa = std.testing.allocator;
    var flat: [4096]u8 = undefined;
    for (&flat, 0..) |*byte, i| byte.* = @truncate(i / 64);
    const small = [_]u8{ 9, 8, 7, 6 };
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    const cases = [_]struct { w: u32, l: u32, pixels: []const u8 }{
        .{ .w = 64, .l = 64, .pixels = &flat },
        .{ .w = 2, .l = 2, .pixels = &small },
    };
    for (cases) |case| {
        var body = try encoded(gpa, .{ .width = case.w, .lines = case.l, .format = .yuv422 }, case.pixels);
        defer body.deinit(gpa);
        for ([_]usize{ 0, 9, 20, body.items.len - 5, body.items.len - 1 }) |at| {
            body.items[at] ^= 0x40;
            try std.testing.expectError(codec.Error.BadCrc, codec.decode(gpa, body.items, &out));
            body.items[at] ^= 0x40;
        }
        _ = try codec.decode(gpa, body.items, &out);
    }
}

test "a short body and a wrong geometry are refused" {
    const gpa = std.testing.allocator;
    const pixels = [_]u8{ 1, 2, 3, 4 };
    var body = try encoded(gpa, .{ .width = 2, .lines = 2, .format = .yuv422 }, &pixels);
    defer body.deinit(gpa);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try std.testing.expectError(codec.Error.Truncated, codec.decode(gpa, body.items[0..10], &out));
    try std.testing.expectError(codec.Error.Truncated, codec.decode(gpa, body.items[0 .. body.items.len - 1], &out));
    var sink: std.Io.Writer.Allocating = .init(gpa);
    defer sink.deinit();
    try std.testing.expectError(codec.Error.BadValue, codec.encode(gpa, &sink.writer, .{ .width = 3, .lines = 2, .format = .yuv422 }, &pixels));
}
