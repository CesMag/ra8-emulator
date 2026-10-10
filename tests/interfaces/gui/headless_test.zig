const std = @import("std");
const ra8 = @import("ra8");
const gui = @import("gui_app");
const render = ra8.render;
const Color = render.draw_list.Color;

test "events come back in the order they were fed, then null" {
    var window = gui.headless.Headless.init(std.testing.allocator, 640, 480);
    defer window.deinit();
    const platform = window.platform();
    try window.feed(.{ .pointer = .{ .x = 3, .y = 4 } });
    try window.feed(.{ .key = .{ .code = 41, .down = true } });
    try window.feed(.quit);
    try std.testing.expectEqual(@as(i32, 3), platform.poll().?.pointer.x);
    try std.testing.expectEqual(@as(u32, 41), platform.poll().?.key.code);
    try std.testing.expect(platform.poll().? == .quit);
    try std.testing.expect(platform.poll() == null);
    try std.testing.expect(platform.poll() == null);
}

test "a resize changes the drawable size once it is polled" {
    var window = gui.headless.Headless.init(std.testing.allocator, 640, 480);
    defer window.deinit();
    const platform = window.platform();
    try window.feed(.{ .resize = .{ .width = 1072, .height = 1448 } });
    try std.testing.expectEqual(@as(u32, 640), platform.size().width);
    _ = platform.poll();
    try std.testing.expectEqual(gui.platform.Size{ .width = 1072, .height = 1448 }, platform.size());
    try std.testing.expectEqual(@as(f32, 1.0), platform.scale());
}

test "present keeps a copy of the frame, so later drawing does not change it" {
    var window = gui.headless.Headless.init(std.testing.allocator, 2, 2);
    defer window.deinit();
    const platform = window.platform();
    var list = render.draw_list.DrawList.init(std.testing.allocator, 2, 2);
    defer list.deinit();
    var frame = try render.raster.Framebuffer.init(std.testing.allocator, 2, 2);
    defer frame.deinit(std.testing.allocator);

    try list.fill(.{ .x = 0, .y = 0, .w = 1, .h = 2 }, Color.rgb(255, 0, 0));
    render.raster.draw(&frame, &list, null);
    try platform.present(&frame);
    @memset(frame.pixels, Color.rgb(0, 255, 0));
    const shown = window.last.?;
    try std.testing.expectEqual(Color.rgb(255, 0, 0), shown.at(0, 1));
    try std.testing.expectEqual(Color{ .r = 0, .g = 0, .b = 0, .a = 0 }, shown.at(1, 1));
    try std.testing.expectEqual(@as(u32, 1), window.presents);
}

test "presenting a frame of another size replaces the copy" {
    var window = gui.headless.Headless.init(std.testing.allocator, 2, 2);
    defer window.deinit();
    const platform = window.platform();
    var small = try render.raster.Framebuffer.init(std.testing.allocator, 2, 2);
    defer small.deinit(std.testing.allocator);
    var large = try render.raster.Framebuffer.init(std.testing.allocator, 4, 3);
    defer large.deinit(std.testing.allocator);
    try platform.present(&small);
    try platform.present(&large);
    try std.testing.expectEqual(@as(u32, 4), window.last.?.width);
    try std.testing.expectEqual(@as(u32, 2), window.presents);
}
