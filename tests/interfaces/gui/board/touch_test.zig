//! Host tests for touch on the board pane's panel (RA8EMU-812): window to
//! panel mapping at two scales and at the edges, and which gesture a press
//! and release make.
const std = @import("std");
const ra8 = @import("ra8");
const gui_app = @import("gui_app");
const pane = gui_app.board_pane;
const touch = gui_app.board.touch;
const Rect = ra8.render.draw_list.Rect;
const proto = ra8.rpc.session.rpc;

const width: u32 = 1024;
const height: u32 = 600;

fn expectPoint(want_x: u16, want_y: u16, got: touch.Point) !void {
    try std.testing.expectEqual(want_x, got.x);
    try std.testing.expectEqual(want_y, got.y);
}

test "the panel maps corner to corner at half and full scale" {
    const scales = [_]Rect{
        .{ .x = 10, .y = 20, .w = 512, .h = 300 },
        .{ .x = 0, .y = 0, .w = 1024, .h = 600 },
    };
    for (scales) |shown| {
        try expectPoint(0, 0, touch.toPanel(shown, width, height, shown.x, shown.y));
        const right = shown.x + shown.w - 1;
        const bottom = shown.y + shown.h - 1;
        try expectPoint(width - 1, height - 1, touch.toPanel(shown, width, height, right, bottom));
        const mid = touch.toPanel(shown, width, height, shown.x + @divTrunc(shown.w, 2), shown.y + @divTrunc(shown.h, 2));
        try expectPoint(512, 300, mid);
    }
}

test "pixels off the panel clamp to its edges" {
    const shown: Rect = .{ .x = 10, .y = 20, .w = 512, .h = 300 };
    try expectPoint(0, 0, touch.toPanel(shown, width, height, -50, -50));
    try expectPoint(width - 1, height - 1, touch.toPanel(shown, width, height, 4000, 4000));
    try expectPoint(0, height - 1, touch.toPanel(shown, width, height, 9, 320));
}

test "the pane shows the panel inside its panel area, keeping the aspect" {
    const layout = pane.Layout.of(.{ .x = 0, .y = 0, .w = 480, .h = 320 });
    const shown = touch.shownIn(layout, width, height);
    try std.testing.expect(!shown.empty());
    try std.testing.expect(shown.x >= layout.panel.x and shown.y >= layout.panel.y);
    try std.testing.expect(shown.x + shown.w <= layout.panel.x + layout.panel.w);
    try std.testing.expect(shown.y + shown.h <= layout.panel.y + layout.panel.h);
    try std.testing.expect(@abs(shown.w * @as(i32, height) - shown.h * @as(i32, width)) <= @as(i32, width));
}

const small: Rect = .{ .x = 0, .y = 0, .w = 512, .h = 300 };

test "a quick press in place is a tap at the panel point" {
    var drag: touch.Drag = .{};
    drag.down(small, width, height, 100, 50, 1_000);
    const gesture = drag.up(small, width, height, 101, 50, 2_000).?;
    try std.testing.expectEqual(proto.InputKind.tap, gesture.kind);
    try expectPoint(200, 100, gesture.from);
    try expectPoint(200, 100, gesture.to);
    try std.testing.expectEqual(@as(?touch.Point, null), drag.start);
}

test "a press held in place is a long press" {
    var drag: touch.Drag = .{};
    drag.down(small, width, height, 100, 50, 0);
    const gesture = drag.up(small, width, height, 100, 50, touch.longpress_ns).?;
    try std.testing.expectEqual(proto.InputKind.longpress, gesture.kind);
    try std.testing.expectEqual(touch.longpress_ns, gesture.duration_ns);
}

test "a drag is a swipe that ends clamped to the panel" {
    var drag: touch.Drag = .{};
    drag.down(small, width, height, 100, 50, 0);
    drag.move(small, width, height, 300, 60);
    const gesture = drag.up(small, width, height, 900, 60, 250_000_000).?;
    try std.testing.expectEqual(proto.InputKind.swipe, gesture.kind);
    try expectPoint(200, 100, gesture.from);
    try expectPoint(width - 1, 120, gesture.to);
    const args = touch.request(.cpu0, gesture, 7);
    try std.testing.expectEqual(@as(u16, width - 1), args.to_x);
    try std.testing.expectEqual(@as(u64, 250_000_000), args.duration_ns);
    try std.testing.expectEqual(@as(u64, 7), args.at_ns);
}

test "a press that starts off the panel makes no gesture" {
    var drag: touch.Drag = .{};
    drag.down(small, width, height, 600, 10, 0);
    try std.testing.expectEqual(@as(?touch.Gesture, null), drag.up(small, width, height, 100, 10, 1));
}
