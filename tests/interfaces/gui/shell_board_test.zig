//! Host tests for the shell's board feed (RA8EMU-790): lcd_dirty rectangles
//! land in the panel image at their place, a later partial rectangle only
//! touches its region, nothing else is taken, and the board leaf draws the
//! image, aspect kept, in place of its note.
const std = @import("std");
const ra8 = @import("ra8");
const gui_app = @import("gui_app");
const status_capture = gui_app.status_capture;
const proto = ra8.rpc.session_rpc;
const draw_list = ra8.render.draw_list;
const raster = ra8.render.raster;
const font = ra8.render.font;
const pane_layout = gui_app.pane_layout;
const frame = gui_app.shell_frame;
const panes = gui_app.shell_panes;
const status_bar = gui_app.status_bar;
const shell_board = gui_app.shell_board;
const fit = gui_app.fit;
const Board = shell_board.Board;
const Color = draw_list.Color;

fn dirty(board: *Board, rect: proto.DirtyRect) !void {
    var bytes: [4096]u8 = undefined;
    const payload = try proto.encode(proto.DirtyRect, rect, &bytes);
    try board.observe(.{ .event = .{ .topic = @backingInt(proto.Topic.lcd_dirty), .payload = payload } });
}

fn gray(level: u8) Color {
    return Color.rgb(level, level, level);
}

fn at(board: *const Board, x: usize, y: usize) Color {
    return board.pixels[y * board.width + x];
}

test "rectangles land at their place and a later one only touches its region" {
    var board = Board.init(std.testing.allocator);
    defer board.deinit();
    try std.testing.expect(!board.hasFrame());

    try dirty(&board, .{ .core = .cpu0, .x = 0, .y = 0, .width = 4, .height = 3, .virtual_ns = 1, .pixels = &(@as([12]u8, @splat(10))) });
    try std.testing.expect(board.hasFrame());
    try std.testing.expectEqual(@as(u32, 4), board.width);
    try std.testing.expectEqual(@as(u32, 3), board.height);

    try dirty(&board, .{ .core = .cpu0, .x = 1, .y = 1, .width = 2, .height = 1, .virtual_ns = 2, .pixels = &.{ 200, 201 } });
    try std.testing.expectEqual(gray(10), at(&board, 0, 1));
    try std.testing.expectEqual(gray(200), at(&board, 1, 1));
    try std.testing.expectEqual(gray(201), at(&board, 2, 1));
    try std.testing.expectEqual(gray(10), at(&board, 3, 1));
    try std.testing.expectEqual(gray(10), at(&board, 1, 0));
}

test "the image grows to cover a rectangle past it, keeping what it held" {
    var board = Board.init(std.testing.allocator);
    defer board.deinit();
    try dirty(&board, .{ .core = .cpu0, .x = 0, .y = 0, .width = 2, .height = 2, .virtual_ns = 1, .pixels = &.{ 1, 2, 3, 4 } });
    try dirty(&board, .{ .core = .cpu0, .x = 3, .y = 2, .width = 1, .height = 1, .virtual_ns = 2, .pixels = &.{9} });
    try std.testing.expectEqual(@as(u32, 4), board.width);
    try std.testing.expectEqual(@as(u32, 3), board.height);
    try std.testing.expectEqual(gray(1), at(&board, 0, 0));
    try std.testing.expectEqual(gray(4), at(&board, 1, 1));
    try std.testing.expectEqual(gray(9), at(&board, 3, 2));
    try std.testing.expectEqual(gray(0), at(&board, 2, 0));
}

test "responses, other topics, the other core and short payloads leave the image alone" {
    var board = Board.init(std.testing.allocator);
    defer board.deinit();
    try board.observe(.{ .response = .{ .id = 1, .result = .{ .ok = "x" } } });
    try board.observe(.{ .event = .{ .topic = @backingInt(proto.Topic.uart), .payload = "x" } });
    try dirty(&board, .{ .core = .cpu1, .x = 0, .y = 0, .width = 1, .height = 1, .virtual_ns = 1, .pixels = &.{5} });
    try dirty(&board, .{ .core = .cpu0, .x = 0, .y = 0, .width = 2, .height = 2, .virtual_ns = 1, .pixels = &.{5} });
    try std.testing.expect(!board.hasFrame());
}

test "fitIn keeps the aspect and centres the image" {
    const body: draw_list.Rect = .{ .x = 10, .y = 20, .w = 200, .h = 100 };
    try std.testing.expectEqual(draw_list.Rect{ .x = 85, .y = 20, .w = 50, .h = 100 }, fit.fitIn(body, 100, 200));
    try std.testing.expectEqual(draw_list.Rect{ .x = 10, .y = 45, .w = 200, .h = 50 }, fit.fitIn(body, 400, 100));
    try std.testing.expectEqual(@as(i32, 0), fit.fitIn(body, 0, 10).w);
}

fn holds(pixels: *const raster.Framebuffer, area: draw_list.Rect, color: Color) bool {
    var y = area.y;
    while (y < area.y + area.h) : (y += 1) {
        var x = area.x;
        while (x < area.x + area.w) : (x += 1) {
            if (std.meta.eql(pixels.at(@intCast(x), @intCast(y)), color)) return true;
        }
    }
    return false;
}

test "the board leaf draws the panel image in place of its note" {
    const gpa = std.testing.allocator;
    var board = Board.init(gpa);
    defer board.deinit();
    try dirty(&board, .{ .core = .cpu0, .x = 0, .y = 0, .width = 4, .height = 6, .virtual_ns = 1, .pixels = &(@as([24]u8, @splat(200))) });
    var layout = try pane_layout.twoCore(gpa);
    defer layout.deinit();
    var solved = try frame.solve(&layout, gpa, 480, 320);
    defer solved.deinit(gpa);
    var list = draw_list.DrawList.init(gpa, 480, 320);
    defer list.deinit();
    var pixels = try raster.Framebuffer.init(gpa, 480, 320);
    defer pixels.deinit(gpa);
    const status: status_bar.Status = .{};
    var painter: panes.Panes = .{ .board = &board };
    try frame.draw(&list, .{ .layout = &layout, .solved = &solved, .strip = status_capture.strip(&status, .closed), .width = 480, .height = 320, .painter = painter.painter() });
    raster.draw(&pixels, &list, font.atlas);
    var boards: usize = 0;
    for (solved.panes.items) |leaf| {
        const placed = layout.pane(leaf.index) orelse continue;
        if (placed.kind != .board) continue;
        boards += 1;
        const body = frame.bodyOf(leaf.area);
        try std.testing.expect(holds(&pixels, fit.fitIn(body, 4, 6), gray(200)));
        try std.testing.expect(!holds(&pixels, body, frame.muted));
    }
    try std.testing.expect(boards > 0);
}
