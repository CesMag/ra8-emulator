//! Covers src/host/camera/pipe_frame.zig: the `PATH,WxH,FORMAT` argument
//! and each raw frame layout widened to RGB.
const std = @import("std");
const ra8 = @import("ra8");

const raw = ra8.host.camera.pipe_frame;

test "the argument splits from the right so a path may hold commas" {
    const arg = try raw.parseArg("/tmp/a,b.fifo,640x480,yuyv");
    try std.testing.expectEqualStrings("/tmp/a,b.fifo", arg.path);
    try std.testing.expectEqual(@as(u32, 640), arg.width);
    try std.testing.expectEqual(@as(u32, 480), arg.height);
    try std.testing.expectEqual(raw.Format.yuyv, arg.format);
    try std.testing.expectEqual(@as(usize, 640 * 480 * 2), arg.frameBytes());
    const stdin = try raw.parseArg("-,2x1,rgb24");
    try std.testing.expectEqualStrings("-", stdin.path);
    try std.testing.expectEqual(@as(usize, 6), stdin.frameBytes());
}

test "a missing path, size or format, or a size no frame can have, is refused" {
    const bad = [_][]const u8{
        "",             "-",          "-,2x2",             ",2x2,rgb24", "-,2x2,nv12", "-,2by2,rgb24", "-,0x2,rgb24",
        "-,2x0,rgb565", "-,3x2,yuyv", "-,5000x5000,rgb24", "-,x2,rgb24",
    };
    for (bad) |text| try std.testing.expectError(error.BadValue, raw.parseArg(text));
}

test "rgb24 is three bytes a pixel in R, G, B order" {
    var out: [6]u8 = undefined;
    raw.toRgb(.rgb24, &.{ 1, 2, 3, 250, 251, 252 }, &out);
    try std.testing.expectEqual([3]u8{ 1, 2, 3 }, out[0..3].*);
    try std.testing.expectEqual([3]u8{ 250, 251, 252 }, out[3..6].*);
}

test "rgb565 is little-endian and widens to full-scale 8-bit channels" {
    var out: [9]u8 = undefined;
    raw.toRgb(.rgb565, &.{ 0x00, 0xF8, 0xE0, 0x07, 0xFF, 0xFF }, &out);
    try std.testing.expectEqual([3]u8{ 255, 0, 0 }, out[0..3].*);
    try std.testing.expectEqual([3]u8{ 0, 255, 0 }, out[3..6].*);
    try std.testing.expectEqual([3]u8{ 255, 255, 255 }, out[6..9].*);
}

test "yuyv shares one chroma pair between two pixels, studio range" {
    var out: [12]u8 = undefined;
    raw.toRgb(.yuyv, &.{ 16, 128, 235, 128, 81, 90, 81, 240 }, &out);
    try std.testing.expectEqual([3]u8{ 0, 0, 0 }, out[0..3].*);
    try std.testing.expectEqual([3]u8{ 255, 255, 255 }, out[3..6].*);
    try std.testing.expectEqualSlices(u8, out[6..9], out[9..12]);
    try std.testing.expect(out[6] > 240 and out[7] < 16 and out[8] < 16);
}
