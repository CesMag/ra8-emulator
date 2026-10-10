//! Covers src/interfaces/render/font.zig: the atlas holds every printable glyph in its
//! own cell, lookups fall back to '?', text fits by whole cells, and drawn
//! text lands in the frame.
const std = @import("std");
const ra8 = @import("ra8");
const font = ra8.render.font;
const draw_list = ra8.render.draw_list;
const raster = ra8.render.raster;
const Color = draw_list.Color;

fn at(x: u32, y: u32) u8 {
    return font.atlas.coverage[y * font.atlas.width + x];
}

test "every glyph stays inside its cell, leaving the spacing blank" {
    try std.testing.expectEqual(@as(u32, 96), font.atlas.width);
    try std.testing.expectEqual(@as(u32, 48), font.atlas.height);
    var char: u8 = font.first;
    while (char <= font.last) : (char += 1) {
        const origin = font.cell(char);
        for (0..font.cell_h) |row| try std.testing.expectEqual(@as(u8, 0), at(origin.x + 5, origin.y + @as(u32, @intCast(row))));
        for (0..font.cell_w) |column| try std.testing.expectEqual(@as(u8, 0), at(origin.x + @as(u32, @intCast(column)), origin.y + 7));
    }
}

test "glyphs have the shapes their codes name" {
    const i = font.cell('I');
    for (0..font.glyph_h) |row| try std.testing.expectEqual(@as(u8, 255), at(i.x + 2, i.y + @as(u32, @intCast(row))));
    try std.testing.expectEqual(@as(u8, 0), at(i.x, i.y + 3));
    const dash = font.cell('-');
    for (0..font.glyph_w) |column| try std.testing.expectEqual(@as(u8, 255), at(dash.x + @as(u32, @intCast(column)), dash.y + 3));
    const space = font.cell(' ');
    for (0..font.cell_h) |row| for (0..font.cell_w) |column| {
        try std.testing.expectEqual(@as(u8, 0), at(space.x + @as(u32, @intCast(column)), space.y + @as(u32, @intCast(row))));
    };
}

test "characters outside printable ASCII show as a question mark" {
    try std.testing.expectEqual(font.cell('?'), font.cell(0x07));
    try std.testing.expectEqual(font.cell('?'), font.cell(0xC3));
    try std.testing.expectEqual(font.Cell{ .x = 0, .y = 0 }, font.cell(' '));
    try std.testing.expectEqual(font.Cell{ .x = 6, .y = 16 }, font.cell('A'));
}

test "text fits by whole cells" {
    try std.testing.expectEqual(@as(u32, 30), font.textWidth(5));
    try std.testing.expectEqualStrings("camer", font.fit("camera.ppm", 35));
    try std.testing.expectEqualStrings("pipe", font.fit("pipe", 100));
    try std.testing.expectEqualStrings("", font.fit("webcam", 5));
}

test "drawn text lands in the frame at its cell positions" {
    const red = Color.rgb(255, 0, 0);
    var list = draw_list.DrawList.init(std.testing.allocator, 20, 10);
    defer list.deinit();
    var frame = try raster.Framebuffer.init(std.testing.allocator, 20, 10);
    defer frame.deinit(std.testing.allocator);
    try font.draw(&list, 1, 1, "I I", red);
    raster.draw(&frame, &list, font.atlas);
    try std.testing.expectEqual(red, frame.at(3, 1));
    try std.testing.expectEqual(red, frame.at(3, 7));
    try std.testing.expectEqual(red, frame.at(15, 4));
    try std.testing.expectEqual(@as(u8, 0), frame.at(1, 4).a);
    try std.testing.expectEqual(@as(u8, 0), frame.at(9, 4).a);
}

test "a centred label is cut to fit and sits in the middle of its area" {
    var list = draw_list.DrawList.init(std.testing.allocator, 64, 64);
    defer list.deinit();
    try font.centred(&list, .{ .x = 10, .y = 20, .w = 24, .h = 24 }, "camera", Color.rgb(1, 2, 3));
    try std.testing.expectEqual(@as(usize, 3), list.commands.items.len);
    const left = list.commands.items[0].shape.glyph.area;
    try std.testing.expectEqual(@as(i32, 10 + @divTrunc(24 - 17, 2)), left.x);
    try std.testing.expectEqual(@as(i32, 20 + @divTrunc(24 - 7, 2)), left.y);
    list.commands.clearRetainingCapacity();
    try font.centred(&list, .{ .x = 0, .y = 0, .w = 6, .h = 8 }, "x", Color.rgb(1, 2, 3));
    try std.testing.expectEqual(@as(usize, 0), list.commands.items.len);
}
