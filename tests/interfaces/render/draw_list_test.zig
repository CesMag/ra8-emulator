const std = @import("std");
const ra8 = @import("ra8");
const draw_list = ra8.render.draw_list;
const Color = draw_list.Color;

const red = Color.rgb(255, 0, 0);

test "a pushed clip narrows the one in force and a pop restores it" {
    var list = draw_list.DrawList.init(std.testing.allocator, 100, 50);
    defer list.deinit();
    try std.testing.expectEqual(draw_list.Rect{ .x = 0, .y = 0, .w = 100, .h = 50 }, list.clip());
    try list.pushClip(.{ .x = 10, .y = 10, .w = 200, .h = 20 });
    try list.pushClip(.{ .x = 0, .y = 15, .w = 30, .h = 30 });
    try std.testing.expectEqual(draw_list.Rect{ .x = 10, .y = 15, .w = 20, .h = 15 }, list.clip());
    list.popClip();
    try std.testing.expectEqual(draw_list.Rect{ .x = 10, .y = 10, .w = 90, .h = 20 }, list.clip());
}

test "each shape carries the clip in force when it was added" {
    var list = draw_list.DrawList.init(std.testing.allocator, 64, 64);
    defer list.deinit();
    try list.fill(.{ .x = 0, .y = 0, .w = 8, .h = 8 }, red);
    try list.pushClip(.{ .x = 4, .y = 4, .w = 8, .h = 8 });
    try list.line(0, 0, 63, 63, red);
    list.popClip();
    try std.testing.expectEqual(@as(usize, 2), list.commands.items.len);
    try std.testing.expectEqual(list.bounds, list.commands.items[0].clip);
    try std.testing.expectEqual(draw_list.Rect{ .x = 4, .y = 4, .w = 8, .h = 8 }, list.commands.items[1].clip);
}

test "shapes outside the clip, or under an empty one, are dropped" {
    var list = draw_list.DrawList.init(std.testing.allocator, 64, 64);
    defer list.deinit();
    try list.fill(.{ .x = 70, .y = 0, .w = 8, .h = 8 }, red);
    try list.glyph(.{ .x = 0, .y = -9, .w = 8, .h = 8 }, 0, 0, red);
    try list.pushClip(.{ .x = 100, .y = 100, .w = 4, .h = 4 });
    try list.line(0, 0, 10, 10, red);
    list.popClip();
    try std.testing.expectEqual(@as(usize, 0), list.commands.items.len);
}

test "clear starts the next frame with no shapes and no clips" {
    var list = draw_list.DrawList.init(std.testing.allocator, 16, 16);
    defer list.deinit();
    try list.pushClip(.{ .x = 0, .y = 0, .w = 4, .h = 4 });
    try list.fill(.{ .x = 0, .y = 0, .w = 2, .h = 2 }, red);
    list.clear();
    try std.testing.expectEqual(@as(usize, 0), list.commands.items.len);
    try std.testing.expectEqual(list.bounds, list.clip());
}

test "centring rounds the odd pixel toward negative infinity, fit or overhang" {
    try std.testing.expectEqual(@as(i32, 4), draw_list.centre(24, 16));
    try std.testing.expectEqual(@as(i32, 0), draw_list.centre(17, 16));
    try std.testing.expectEqual(@as(i32, 0), draw_list.centre(16, 16));
    // A thing larger than its room: toward zero would say 0, -1, -1, -2.
    try std.testing.expectEqual(@as(i32, -1), draw_list.centre(15, 16));
    try std.testing.expectEqual(@as(i32, -1), draw_list.centre(14, 16));
    try std.testing.expectEqual(@as(i32, -2), draw_list.centre(13, 16));
    try std.testing.expectEqual(@as(i32, -2), draw_list.centre(12, 16));
    try std.testing.expectEqual(@as(i32, -8), draw_list.centre(0, 16));
}

test "a centred thing moves one pixel for every two its room shrinks, with no stall at the fit" {
    var room: i32 = 40;
    var last = draw_list.centre(room, 16);
    var held: u32 = 1;
    while (room > -8) {
        room -= 1;
        const now = draw_list.centre(room, 16);
        try std.testing.expect(now == last or now == last - 1);
        held = if (now == last) held + 1 else 1;
        try std.testing.expect(held <= 2);
        // The overhang is split evenly: never more than a pixel apart.
        const over_far = 16 + now - room;
        try std.testing.expect(over_far == -now or over_far == -now - 1);
        last = now;
    }
}
