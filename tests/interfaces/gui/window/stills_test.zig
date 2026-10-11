//! Tests for src/interfaces/gui/window_stills.zig: the recorder passes the
//! window through untouched and keeps every n-th frame as a numbered PNG.
const std = @import("std");
const ra8 = @import("ra8");
const cli_app = @import("cli_app");
const gui_app = @import("gui_app");
const stills = gui_app.window.stills;
const png = cli_app.report.png;
const raster = ra8.render.raster;
const Headless = gui_app.headless.Headless;
const Color = ra8.render.draw_list.Color;

fn frameOf(shade: u8) !raster.Framebuffer {
    const frame = try raster.Framebuffer.init(std.testing.allocator, 4, 3);
    @memset(frame.pixels, Color.rgb(shade, shade, shade));
    return frame;
}

test "the recorder passes events, size, scale and frames through" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var window = Headless.init(std.testing.allocator, 640, 480);
    defer window.deinit();
    window.dpi = 2.0;
    try window.feed(.quit);
    var recorder = stills.Recorder{ .allocator = std.testing.allocator, .inner = window.platform(), .io = std.testing.io, .dir = tmp.dir, .stem = "w" };
    const shown = recorder.platform();
    try std.testing.expectEqual(@as(u32, 640), shown.size().width);
    try std.testing.expectEqual(@as(f32, 2.0), shown.scale());
    try std.testing.expect(shown.poll().? == .quit);
    try std.testing.expect(shown.poll() == null);
    var frame = try frameOf(5);
    defer frame.deinit(std.testing.allocator);
    try shown.present(&frame);
    try std.testing.expectEqual(@as(u32, 1), window.presents);
    try std.testing.expectEqual(Color.rgb(5, 5, 5), window.last.?.pixels[0]);
}

test "every n-th frame is kept, numbered from zero" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var window = Headless.init(std.testing.allocator, 4, 3);
    defer window.deinit();
    var recorder = stills.Recorder{ .allocator = std.testing.allocator, .inner = window.platform(), .io = std.testing.io, .dir = tmp.dir, .stem = "pane", .every = 2 };
    const shown = recorder.platform();
    for (0..5) |shade| {
        var frame = try frameOf(@intCast(shade));
        defer frame.deinit(std.testing.allocator);
        try shown.present(&frame);
    }
    try std.testing.expectEqual(@as(u32, 5), recorder.frames);
    try std.testing.expectEqual(@as(u32, 3), recorder.saved);
    for ([_][]const u8{ "pane-0000.png", "pane-0001.png", "pane-0002.png" }) |file_name| {
        const bytes = try tmp.dir.readFileAlloc(std.testing.io, file_name, std.testing.allocator, .limited(1 << 16));
        defer std.testing.allocator.free(bytes);
        try std.testing.expectEqualSlices(u8, &png.signature, bytes[0..8]);
    }
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(std.testing.io, "pane-0003.png", .{}));
}

test "an every of zero keeps each frame" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var window = Headless.init(std.testing.allocator, 4, 3);
    defer window.deinit();
    const recorder = stills.Recorder{ .allocator = std.testing.allocator, .inner = window.platform(), .io = std.testing.io, .dir = tmp.dir, .stem = "w", .every = 0 };
    try std.testing.expect(recorder.keeps(0));
    try std.testing.expect(recorder.keeps(7));
}

test "the stills directory is made when asked for and absent otherwise" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try std.testing.expect((try stills.openDir(std.testing.io, null)) == null);
    var base: [std.fs.max_path_bytes]u8 = undefined;
    const root = base[0..try tmp.dir.realPath(std.testing.io, &base)];
    const path = try std.fs.path.join(std.testing.allocator, &.{ root, "shots", "pane" });
    defer std.testing.allocator.free(path);
    const dir = (try stills.openDir(std.testing.io, path)).?;
    defer dir.close(std.testing.io);
    try tmp.dir.access(std.testing.io, "shots/pane", .{});
}
