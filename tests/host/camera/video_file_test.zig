//! Covers src/host/camera/video_file.zig: frames picked by emulated
//! time alone, so every speed mode sees the same frame at the same instant;
//! the last frame held or the clip looped past the end; and a clip on disk
//! captured frame by frame through the camera's hosted source.
const std = @import("std");
const ra8 = @import("ra8");

const video = ra8.host.camera.video_file;
const camera = ra8.chip.periph.ceu.camera;
const allocator = std.testing.allocator;
const ms = std.time.ns_per_ms;

/// Three 2x2 4:2:0 frames at 25 fps: black, white, red.
const clip = "YUV4MPEG2 W2 H2 F25:1 Ip C420jpeg\n" ++
    "FRAME\n" ++ [_]u8{ 16, 16, 16, 16, 128, 128 } ++
    "FRAME\n" ++ [_]u8{ 235, 235, 235, 235, 128, 128 } ++
    "FRAME\n" ++ [_]u8{ 81, 81, 81, 81, 90, 240 };

/// RGB565 little-endian, one line of the 2x2 frame.
const black = [_]u8{ 0x00, 0x00, 0x00, 0x00 };
const white = [_]u8{ 0xFF, 0xFF, 0xFF, 0xFF };
const red = [_]u8{ 0x00, 0xF8, 0x00, 0xF8 };

var rgb565: u8 = 0x6F;

fn open(dir: std.testing.TmpDir, bytes: []const u8, suffix: []const u8) !*video.Clip {
    try dir.dir.writeFile(std.testing.io, .{ .sub_path = "clip.y4m", .data = bytes });
    const path = try dir.dir.realPathFileAlloc(std.testing.io, "clip.y4m", allocator);
    defer allocator.free(path);
    const arg = try std.mem.concat(allocator, u8, &.{ path, suffix });
    defer allocator.free(arg);
    return video.Clip.load(allocator, std.testing.io, arg);
}

fn capture(loaded: *video.Clip) !camera.frame_source.FrameSource {
    return ra8.components.camera.hosted.Hosted(video.Clip).open(allocator, loaded, &rgb565, "video", "clip.y4m");
}

fn expectLine(source: camera.frame_source.FrameSource, when: u64, expected: []const u8) !void {
    source.frame(when, .{ .width = 4, .lines = 2 });
    var line: [4]u8 = undefined;
    source.fill(1, 0, &line);
    try std.testing.expectEqualSlices(u8, expected, &line);
}

test "PATH and PATH,loop" {
    try std.testing.expectEqualDeep(video.Arg{ .path = "a.y4m", .loop = false }, video.parseArg("a.y4m"));
    try std.testing.expectEqualDeep(video.Arg{ .path = "a.y4m", .loop = true }, video.parseArg("a.y4m,loop"));
}

test "the frame shown depends on emulated time only, whatever the speed" {
    // A slow, real-time and fast run reach the same emulated instants in
    // steps of 1 ms, 40 ms and 4 s; each instant picks the same frame.
    const instants = [_]u64{ 0, 39 * ms, 40 * ms, 79 * ms, 80 * ms, 119 * ms, 120 * ms, 4000 * ms };
    const expected = [_]usize{ 0, 0, 1, 1, 2, 2, 2, 2 };
    for ([_]u64{ 1 * ms, 40 * ms, 4000 * ms }) |step| {
        var now: u64 = 0;
        for (instants, expected) |instant, frame| {
            while (now + step <= instant) now += step;
            now = instant;
            try std.testing.expectEqual(frame, video.frameAt(25, 1, 3, false, now));
        }
    }
}

test "past the end the last frame holds, or the clip wraps with loop" {
    try std.testing.expectEqual(@as(usize, 2), video.frameAt(25, 1, 3, false, 160 * ms));
    try std.testing.expectEqual(@as(usize, 1), video.frameAt(25, 1, 3, true, 160 * ms));
    try std.testing.expectEqual(@as(usize, 0), video.frameAt(25, 1, 3, true, 120 * ms));
    try std.testing.expectEqual(@as(usize, 1), video.frameAt(30000, 1001, 3, false, 34 * ms));
}

test "a clip on disk is captured frame by frame, then held" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const loaded = try open(tmp, clip, "");
    const source = try capture(loaded);
    defer source.close();
    try expectLine(source, 0, &black);
    try expectLine(source, 40 * ms, &white);
    try expectLine(source, 80 * ms, &red);
    try expectLine(source, 10_000 * ms, &red);
}

test "a looping clip on disk wraps back to its first frame" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const loaded = try open(tmp, clip, ",loop");
    const source = try capture(loaded);
    defer source.close();
    try expectLine(source, 120 * ms, &black);
    try expectLine(source, 160 * ms, &white);
}

test "a frame cut short at the end of the file is dropped" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const loaded = try open(tmp, clip ++ "FRAME\n" ++ [_]u8{ 235, 235 }, "");
    defer loaded.close();
    try std.testing.expectEqual(@as(usize, 3), loaded.offsets.len);
}

test "a missing, frameless or unsupported clip refuses the run" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try std.testing.expectError(error.FileNotFound, video.Clip.load(allocator, std.testing.io, "/nonexistent/ra8.y4m"));
    try std.testing.expectError(error.Truncated, open(tmp, "YUV4MPEG2 W2 H2\n", ""));
    try std.testing.expectError(error.Unsupported, open(tmp, "YUV4MPEG2 W2 H2 It\nFRAME\n", ""));
}
