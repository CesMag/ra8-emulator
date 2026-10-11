//! Host tests for the shell's board feed (RA8EMU-790, RA8EMU-1119):
//! lcd_dirty rectangles land in the panel image at their place, a later
//! partial rectangle only touches its region, an LED change on the session
//! topic lights its LED, nothing else is taken, and the board leaf draws the
//! board pane, with the image in its panel slot and with or without one.
const std = @import("std");
const dark = &@import("gui_app").colors.palettes.dark;
const colors_mod = @import("gui_app").colors;
const ra8 = @import("ra8");
const gui_app = @import("gui_app");
const status_capture = gui_app.status.capture;
const proto = ra8.rpc.session.rpc;
const draw_list = ra8.render.draw_list;
const raster = ra8.render.raster;
const font = ra8.render.font;
const pane_layout = gui_app.pane_layout;
const frame = gui_app.shell.frame;
const panes = gui_app.shell.panes;
const status_bar = gui_app.status.bar;
const shell_board = gui_app.shell.board;
const fit = gui_app.fit;
const board_pane = gui_app.board_pane;
const board_touch = gui_app.board.touch;
const Rig = @import("../../local_rig.zig").Rig;
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

fn led(board: *Board, event: proto.SessionEvent) !void {
    var bytes: [64]u8 = undefined;
    const payload = try proto.encode(proto.SessionEvent, event, &bytes);
    try board.observe(.{ .event = .{ .topic = @backingInt(proto.Topic.session), .payload = payload } });
}

test "an LED change for cpu0 on the session topic sets its LED, and nothing else on it does" {
    var board = Board.init(std.testing.allocator);
    defer board.deinit();
    try led(&board, .{ .core = .cpu0, .kind = .led_changed, .address = 0x100 });
    try led(&board, .{ .core = .cpu0, .kind = .led_changed, .address = 0x102 });
    try std.testing.expectEqual([_]bool{ true, false, true }, board.leds.on);
    try led(&board, .{ .core = .cpu0, .kind = .led_changed, .address = 0x000 });
    try led(&board, .{ .core = .cpu1, .kind = .led_changed, .address = 0x101 });
    try led(&board, .{ .core = .cpu0, .kind = .plugged, .address = 0x101 });
    try std.testing.expectEqual([_]bool{ false, false, true }, board.leds.on);
    try board.observe(.{ .event = .{ .topic = @backingInt(proto.Topic.session), .payload = "x" } });
    try std.testing.expect(!board.hasFrame());
}

test "once the session greets, the feed subscribes the panel and the session topic, once" {
    var rig: Rig = undefined;
    try rig.open("tests/fixtures/fpu/fp_basic.elf");
    defer rig.deinit();
    var board = Board.init(std.testing.allocator);
    defer board.deinit();
    const context = &rig.session.setup.context;
    try std.testing.expect(!context.wants(.cpu0, .session));
    board.attach(&rig.link);
    try rig.session.answer();
    try std.testing.expect(context.wants(.cpu0, .session));
    try std.testing.expect(context.wants(.cpu0, .lcd_dirty));
    var answers: usize = 0;
    while (rig.link.pump()) |_| answers += 1;
    board.attach(&rig.link);
    try rig.session.answer();
    while (rig.link.pump()) |_| answers += 1;
    try std.testing.expectEqual(@as(usize, 2), answers);
}

/// The two-core layout's frame with `board` behind its board leaf, drawn at
/// `width` by `height`, and that leaf's body.
const Drawn = struct {
    pixels: raster.Framebuffer,
    body: draw_list.Rect,

    fn of(board: *const Board, width: u32, height: u32) !Drawn {
        const gpa = std.testing.allocator;
        var layout = try pane_layout.twoCore(gpa);
        defer layout.deinit();
        var solved = try frame.solve(&layout, gpa, @intCast(width), @intCast(height));
        defer solved.deinit(gpa);
        var list = draw_list.DrawList.init(gpa, width, height);
        defer list.deinit();
        var pixels = try raster.Framebuffer.init(gpa, width, height);
        errdefer pixels.deinit(gpa);
        const status: status_bar.Status = .{};
        var painter: panes.Panes = .{ .board = board };
        try frame.draw(&list, dark, .{ .layout = &layout, .solved = &solved, .strip = status_capture.strip(&status, .closed), .width = @intCast(width), .height = @intCast(height), .painter = painter.painter() });
        raster.draw(&pixels, &list, font.atlas);
        for (solved.panes.items) |leaf| {
            const placed = layout.pane(leaf.index) orelse continue;
            if (placed.kind == .board) return .{ .pixels = pixels, .body = frame.bodyOf(leaf.area) };
        }
        return error.NoBoardLeaf;
    }

    fn middle(self: *const Drawn, area: draw_list.Rect) Color {
        return self.pixels.at(@intCast(area.x + @divTrunc(area.w, 2)), @intCast(area.y + @divTrunc(area.h, 2)));
    }
};

test "the board leaf draws the board pane: the panel image in its slot and the LEDs as reported" {
    var board = Board.init(std.testing.allocator);
    defer board.deinit();
    try dirty(&board, .{ .core = .cpu0, .x = 0, .y = 0, .width = 4, .height = 6, .virtual_ns = 1, .pixels = &(@as([24]u8, @splat(200))) });
    try led(&board, .{ .core = .cpu0, .kind = .led_changed, .address = 0x100 });
    var drawn = try Drawn.of(&board, 640, 480);
    defer drawn.pixels.deinit(std.testing.allocator);
    const parts = board_pane.Layout.of(drawn.body);
    try std.testing.expect(!parts.board.empty());
    try std.testing.expectEqual(gray(200), drawn.middle(board_touch.shownIn(parts, 4, 6)));
    try std.testing.expectEqual(board_pane.lampOf(board_pane.led_rgb565[0]), drawn.middle(parts.leds[0]));
    try std.testing.expectEqual(dark.led_off, drawn.middle(parts.leds[1]));
    try std.testing.expectEqual(dark.face, drawn.middle(parts.switches[0]));
}

test "with no panel frame the board leaf still shows the board and its LEDs" {
    var board = Board.init(std.testing.allocator);
    defer board.deinit();
    try led(&board, .{ .core = .cpu0, .kind = .led_changed, .address = 0x101 });
    var drawn = try Drawn.of(&board, 640, 480);
    defer drawn.pixels.deinit(std.testing.allocator);
    const parts = board_pane.Layout.of(drawn.body);
    try std.testing.expectEqual(colors_mod.unseen, drawn.middle(parts.panel));
    try std.testing.expectEqual(dark.led_off, drawn.middle(parts.leds[0]));
    try std.testing.expectEqual(board_pane.lampOf(board_pane.led_rgb565[1]), drawn.middle(parts.leds[1]));
}

test "a leaf too small for the board shows the panel image alone, or its note" {
    var board = Board.init(std.testing.allocator);
    defer board.deinit();
    var waiting = try Drawn.of(&board, 300, 200);
    defer waiting.pixels.deinit(std.testing.allocator);
    try std.testing.expect(board_pane.Layout.of(waiting.body).board.empty());
    try std.testing.expect(holds(&waiting.pixels, waiting.body, dark.muted));

    try dirty(&board, .{ .core = .cpu0, .x = 0, .y = 0, .width = 4, .height = 6, .virtual_ns = 1, .pixels = &(@as([24]u8, @splat(200))) });
    var shown = try Drawn.of(&board, 300, 200);
    defer shown.pixels.deinit(std.testing.allocator);
    try std.testing.expectEqual(gray(200), shown.middle(fit.fitIn(shown.body, 4, 6)));
    try std.testing.expect(!holds(&shown.pixels, shown.body, dark.muted));
}
