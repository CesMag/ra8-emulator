//! Covers src/interfaces/render/gfx_font.zig: the atlas holds every printable
//! ra8_gfx sans glyph in its own cell, lookups fall back to '?', text fits by
//! whole cells, and drawn text lands in the frame.
const std = @import("std");
const ra8 = @import("ra8");
const font = ra8.render.font;
const draw_list = ra8.render.draw_list;
const raster = ra8.render.raster;
const Color = draw_list.Color;

fn at(x: u32, y: u32) u8 {
    return font.atlas.coverage[y * font.atlas.width + x];
}

fn lit(char: u8) u32 {
    const origin = font.cell(char);
    var count: u32 = 0;
    for (0..font.cell_h) |row| for (0..font.cell_w) |column| {
        if (at(origin.x + @as(u32, @intCast(column)), origin.y + @as(u32, @intCast(row))) != 0) count += 1;
    };
    return count;
}

test "the atlas uses the firmware's 8x16 sans cells, sixteen to a row" {
    try std.testing.expectEqual(@as(u32, 8), font.cell_w);
    try std.testing.expectEqual(@as(u32, 16), font.cell_h);
    try std.testing.expectEqual(@as(u32, 128), font.atlas.width);
    try std.testing.expectEqual(@as(u32, 96), font.atlas.height);
}

test "every printable glyph but space has ink and space has none" {
    try std.testing.expectEqual(@as(u32, 0), lit(' '));
    var char: u8 = font.first + 1;
    while (char <= font.last) : (char += 1) try std.testing.expect(lit(char) > 0);
}

test "glyphs have the shapes their codes name" {
    const i = font.cell('I');
    var tallest: u32 = 0;
    for (0..font.cell_w) |column| {
        var run: u32 = 0;
        for (0..font.cell_h) |row| {
            if (at(i.x + @as(u32, @intCast(column)), i.y + @as(u32, @intCast(row))) != 0) run += 1;
        }
        tallest = @max(tallest, run);
    }
    try std.testing.expect(tallest >= 8);
    const dash = font.cell('-');
    var widest: u32 = 0;
    for (0..font.cell_h) |row| {
        var run: u32 = 0;
        for (0..font.cell_w) |column| {
            if (at(dash.x + @as(u32, @intCast(column)), dash.y + @as(u32, @intCast(row))) != 0) run += 1;
        }
        widest = @max(widest, run);
    }
    try std.testing.expect(widest >= 5);
    try std.testing.expect(lit('W') > lit('.'));
}

test "characters outside printable ASCII show as a question mark" {
    try std.testing.expectEqual(font.cell('?'), font.cell(0x07));
    try std.testing.expectEqual(font.cell('?'), font.cell(0xC3));
    try std.testing.expectEqual(font.Cell{ .x = 0, .y = 0 }, font.cell(' '));
    try std.testing.expectEqual(font.Cell{ .x = 8, .y = 32 }, font.cell('A'));
}

test "text fits by whole cells" {
    try std.testing.expectEqual(@as(u32, 40), font.textWidth(5));
    try std.testing.expectEqualStrings("came", font.fit("camera.ppm", 35));
    try std.testing.expectEqualStrings("pipe", font.fit("pipe", 100));
    try std.testing.expectEqualStrings("", font.fit("webcam", 5));
}

test "drawn text lands in the frame at its cell positions" {
    const red = Color.rgb(255, 0, 0);
    var list = draw_list.DrawList.init(std.testing.allocator, 40, 20);
    defer list.deinit();
    var frame = try raster.Framebuffer.init(std.testing.allocator, 40, 20);
    defer frame.deinit(std.testing.allocator);
    try font.draw(&list, 1, 1, "I I", red);
    try std.testing.expectEqual(@as(usize, 2), list.commands.items.len);
    raster.draw(&frame, &list, font.atlas);
    var left: u32 = 0;
    var gap: u32 = 0;
    var right: u32 = 0;
    for (1..17) |y| for (0..40) |x| {
        if (frame.at(@intCast(x), @intCast(y)).a == 0) continue;
        if (x < 9) left += 1 else if (x < 17) gap += 1 else right += 1;
    };
    try std.testing.expect(left > 0);
    try std.testing.expectEqual(@as(u32, 0), gap);
    try std.testing.expectEqual(left, right);
}

test "a centred label is cut to fit and sits in the middle of its area" {
    var list = draw_list.DrawList.init(std.testing.allocator, 64, 64);
    defer list.deinit();
    try font.centred(&list, .{ .x = 10, .y = 20, .w = 40, .h = 24 }, "camera", Color.rgb(1, 2, 3));
    try std.testing.expectEqual(@as(usize, 4), list.commands.items.len);
    const first = list.commands.items[0].shape.glyph.area;
    try std.testing.expectEqual(@as(i32, 14), first.x);
    try std.testing.expectEqual(@as(i32, 24), first.y);
    list.commands.clearRetainingCapacity();
    try font.centred(&list, .{ .x = 0, .y = 0, .w = 6, .h = 8 }, "x", Color.rgb(1, 2, 3));
    try std.testing.expectEqual(@as(usize, 0), list.commands.items.len);
}

test "text drawn at negative offsets keeps its shapes; only the target clips" {
    const ink = Color.rgb(255, 0, 0);
    var list = draw_list.DrawList.init(std.testing.allocator, 64, 32);
    defer list.deinit();
    var baseline = try raster.Framebuffer.init(std.testing.allocator, 64, 32);
    defer baseline.deinit(std.testing.allocator);
    var frame = try raster.Framebuffer.init(std.testing.allocator, 64, 32);
    defer frame.deinit(std.testing.allocator);
    try font.draw(&list, 10, 12, "WIWI", ink);
    raster.draw(&baseline, &list, font.atlas);
    list.commands.clearRetainingCapacity();
    try font.draw(&list, 3, 3, "WIWI", ink);
    raster.draw(&frame, &list, font.atlas);
    // "WIWI" is four cells wide, so the run at (3, 3) names the baseline
    // run's pixel seven right and nine down, and names it in bounds: the
    // overlap must match exactly, so no round-toward-zero clipped, sheared
    // or skewed a negative position.
    var overlap: usize = 0;
    for (0..23) |py| for (0..57) |px| {
        const shifted = frame.at(@intCast(px), @intCast(py)).a != 0;
        const named = baseline.at(@intCast(px + 7), @intCast(py + 9)).a != 0;
        try std.testing.expectEqual(named, shifted);
        if (shifted) overlap += 1;
    };
    try std.testing.expect(overlap > 100);
    // Nothing ink outside the overlap: negative positions drew nothing
    // off-target.
    for (0..32) |py| for (0..64) |px| {
        if (px < 35 and py < 19) continue;
        try std.testing.expectEqual(@as(u8, 0), frame.at(@intCast(px), @intCast(py)).a);
    };
}
