//! Tests for src/interfaces/gui/window_still.zig: a window frame leaves as
//! an opaque PNG of its own size, and stills are numbered in order.
const std = @import("std");
const ra8 = @import("ra8");
const cli_app = @import("cli_app");
const gui_app = @import("gui_app");
const still = gui_app.window.still;
const png = cli_app.report.png;
const raster = ra8.render.raster;
const Color = ra8.render.draw_list.Color;

test "a window frame goes out opaque, channel for channel" {
    const pixels = [_]Color{ .{ .r = 1, .g = 2, .b = 3, .a = 0 }, Color.rgb(200, 100, 50) };
    var rgba: [8]u8 = undefined;
    try still.opaqueRgba(&pixels, &rgba);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 1, 2, 3, 0xFF, 200, 100, 50, 0xFF }, &rgba);
    var short: [4]u8 = undefined;
    try std.testing.expectError(png.Error.BadShape, still.opaqueRgba(&pixels, &short));
}

test "a saved still is a PNG of the frame's size" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var frame = try raster.Framebuffer.init(std.testing.allocator, 3, 2);
    defer frame.deinit(std.testing.allocator);
    @memset(frame.pixels, Color.rgb(9, 8, 7));
    try still.save(std.testing.allocator, std.testing.io, tmp.dir, "w.png", frame);
    const bytes = try tmp.dir.readFileAlloc(std.testing.io, "w.png", std.testing.allocator, .limited(1 << 16));
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualSlices(u8, &png.signature, bytes[0..8]);
    try std.testing.expectEqualStrings("IHDR", bytes[12..16]);
    try std.testing.expectEqual(@as(u32, 3), std.mem.readInt(u32, bytes[16..20], .big));
    try std.testing.expectEqual(@as(u32, 2), std.mem.readInt(u32, bytes[20..24], .big));
}

test "stills are numbered so they sort in the order taken" {
    var buffer: [32]u8 = undefined;
    try std.testing.expectEqualStrings("pane-0003.png", try still.name(&buffer, "pane", 3));
    try std.testing.expectEqualStrings("pane-0120.png", try still.name(&buffer, "pane", 120));
}
