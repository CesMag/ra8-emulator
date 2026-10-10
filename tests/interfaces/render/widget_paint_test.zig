const std = @import("std");
const ra8 = @import("ra8");
const widget = @import("ra8_widget");
const draw_list = ra8.render.draw_list;
const raster = ra8.render.raster;
const font = ra8.render.font;
const widget_paint = ra8.render.widget_paint;

fn bare(rect: widget.types.Rect) widget.types.Widget {
    return .{ .vt = null, .ctx = null, .rect = rect, .fixed = 0, .flex = 0, .action_id = 0, .refresh = 0, .visible = false, .dirty = false };
}

test "colorOf splits the firmware colour word into opaque rgb" {
    const c = widget_paint.colorOf(0x00123456);
    try std.testing.expectEqual(draw_list.Color{ .r = 0x12, .g = 0x34, .b = 0x56, .a = 255 }, c);
}

test "a firmware label paints its fill and glyphs into the draw list" {
    var list = draw_list.DrawList.init(std.testing.allocator, 120, 20);
    defer list.deinit();
    var target = widget_paint.Target{ .list = &list };
    const paint = target.paint();
    var label = widget.label.Label{ .paint = &paint, .text = "RA8", .fg = 0x000000, .bg = 0xffffff, .pad = 2, .alignment = .left, .face = .sans };
    var w = bare(.{ .x = 0, .y = 0, .w = 120, .h = 20 });
    try std.testing.expectEqual(widget.label.err.ok, widget.label.ra8_widget_label_init(&w, &label));
    w.vt.?.render.?(&w);
    try std.testing.expect(!target.failed);
    var fills: usize = 0;
    var glyphs: usize = 0;
    for (list.commands.items) |command| switch (command.shape) {
        .fill => fills += 1,
        .glyph => glyphs += 1,
        else => {},
    };
    try std.testing.expect(fills >= 1);
    try std.testing.expectEqual(@as(usize, 3), glyphs);
}

test "the painted label rasterizes dark text on its white fill" {
    var list = draw_list.DrawList.init(std.testing.allocator, 120, 20);
    defer list.deinit();
    var target = widget_paint.Target{ .list = &list };
    const paint = target.paint();
    var label = widget.label.Label{ .paint = &paint, .text = "RA8", .fg = 0x000000, .bg = 0xffffff, .pad = 2, .alignment = .left, .face = .sans };
    var w = bare(.{ .x = 0, .y = 0, .w = 120, .h = 20 });
    _ = widget.label.ra8_widget_label_init(&w, &label);
    w.vt.?.render.?(&w);
    var frame = try raster.Framebuffer.init(std.testing.allocator, 120, 20);
    defer frame.deinit(std.testing.allocator);
    raster.draw(&frame, &list, font.atlas);
    var dark: usize = 0;
    var light: usize = 0;
    for (0..20) |y| for (0..120) |x| {
        const px = frame.at(@intCast(x), @intCast(y));
        if (px.r < 64) dark += 1;
        if (px.r > 192) light += 1;
    };
    try std.testing.expect(dark > 0);
    try std.testing.expect(light > dark);
}
