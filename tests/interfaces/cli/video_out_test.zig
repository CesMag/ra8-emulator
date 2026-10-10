//! Tests for virtual-time Y4M and MP4 panel video output.
const std = @import("std");
const cli_app = @import("cli_app");
const video_out = cli_app.video_out;

fn outputPath(tmp: *std.testing.TmpDir, allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    return try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/{s}", .{ tmp.sub_path, name });
}

fn frameCount(bytes: []const u8) usize {
    var count: usize = 0;
    var cursor: usize = 0;
    while (std.mem.indexOfPos(u8, bytes, cursor, "FRAME\n")) |at| {
        count += 1;
        cursor = at + 6;
    }
    return count;
}

test "Y4M writes exact grayscale frames held at ten virtual frames per second" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try outputPath(&tmp, std.testing.allocator, "capture.y4m");
    defer std.testing.allocator.free(path);
    var writer = try video_out.Writer.init(std.testing.allocator, std.testing.io, path);
    defer writer.deinit();
    const black = @as([4]u32, @splat(0xFF000000));
    const white = @as([4]u32, @splat(0xFFFFFFFF));
    try writer.record(2, 2, &black, 100);
    try writer.record(2, 2, &white, 200_000_100);
    try writer.finish();

    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, std.testing.allocator, .limited(4096));
    defer std.testing.allocator.free(bytes);
    const stream_header = "YUV4MPEG2 W2 H2 F10:1 Ip A1:1 Cmono\n";
    try std.testing.expect(std.mem.startsWith(u8, bytes, stream_header));
    try std.testing.expectEqual(@as(usize, 12), frameCount(bytes));
    const header_len = stream_header.len;
    try std.testing.expectEqualStrings("FRAME\n", bytes[header_len .. header_len + 6]);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0 }, bytes[header_len + 6 .. header_len + 10]);
    const white_start = header_len + 2 * 10;
    try std.testing.expectEqualStrings("FRAME\n", bytes[white_start .. white_start + 6]);
    try std.testing.expectEqualSlices(u8, &.{ 255, 255, 255, 255 }, bytes[white_start + 6 .. white_start + 10]);
}

test "MP4 decodes virtual-time frames with the expected duration and quality" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try outputPath(&tmp, std.testing.allocator, "capture.mp4");
    defer std.testing.allocator.free(path);
    var writer = video_out.Writer.init(std.testing.allocator, std.testing.io, path) catch |err| {
        if (err == error.FfmpegNotFound) return error.SkipZigTest;
        return err;
    };
    defer writer.deinit();
    const black = @as([256]u32, @splat(0xFF000000));
    const white = @as([256]u32, @splat(0xFFFFFFFF));
    try writer.record(16, 16, &black, 0);
    try writer.record(16, 16, &white, 200_000_000);
    try writer.finish();

    const decoded = try std.process.run(std.testing.allocator, std.testing.io, .{
        .argv = &.{ "ffmpeg", "-v", "error", "-i", path, "-f", "rawvideo", "-pix_fmt", "gray", "-" },
        .stdout_limit = .limited(16 * 16 * 20),
    });
    defer std.testing.allocator.free(decoded.stdout);
    defer std.testing.allocator.free(decoded.stderr);
    try std.testing.expect(decoded.term == .exited and decoded.term.exited == 0);
    const frame_bytes = 16 * 16;
    try std.testing.expectEqual(@as(usize, 12 * frame_bytes), decoded.stdout.len);
    var total_error: u64 = 0;
    for (decoded.stdout[0 .. 2 * frame_bytes]) |pixel| total_error += pixel;
    try std.testing.expect(total_error < 2 * frame_bytes * 3);
    total_error = 0;
    for (decoded.stdout[2 * frame_bytes ..]) |pixel| total_error += 255 - pixel;
    try std.testing.expect(total_error < 10 * frame_bytes * 3);
}
