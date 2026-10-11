//! Host tests for the board pane at any size (RA8EMU-965): the panel keeps
//! its aspect and sits centred in its slot, touch and switch coordinates
//! round-trip at each size, a press in the letterbox bars lands on nothing,
//! and the panel is sampled nearest at whole-number scales and filtered
//! otherwise.
const std = @import("std");
const ra8 = @import("ra8");
const gui_app = @import("gui_app");
const pane = gui_app.board_pane;
const touch = gui_app.board.touch;
const Rect = ra8.render.draw_list.Rect;

const width: u32 = 1024;
const height: u32 = 600;

/// Smaller than native, near native, about 2x, odd fractional, very wide,
/// very tall.
const areas = [_]Rect{
    .{ .x = 0, .y = 0, .w = 320, .h = 200 },
    .{ .x = 0, .y = 0, .w = 1600, .h = 1000 },
    .{ .x = 0, .y = 0, .w = 3000, .h = 2000 },
    .{ .x = 7, .y = 3, .w = 777, .h = 513 },
    .{ .x = 0, .y = 0, .w = 3000, .h = 300 },
    .{ .x = 0, .y = 0, .w = 300, .h = 2000 },
};

fn within(a: i64, b: i64, slack: i64) bool {
    return @abs(a - b) <= slack;
}

test "the panel keeps its aspect and sits centred in its slot at every size" {
    for (areas) |area| {
        const parts = pane.Layout.of(area);
        const shown = touch.shownIn(parts, width, height);
        try std.testing.expect(!shown.empty());
        try std.testing.expect(within(@as(i64, shown.w) * height, @as(i64, shown.h) * width, width));
        try std.testing.expect(shown.w == parts.panel.w or shown.h == parts.panel.h);
        const left = shown.x - parts.panel.x;
        const right = parts.panel.x + parts.panel.w - shown.x - shown.w;
        const top = shown.y - parts.panel.y;
        const bottom = parts.panel.y + parts.panel.h - shown.y - shown.h;
        try std.testing.expect(within(left, right, 1) and within(top, bottom, 1));
    }
}

test "touch corners and centre round-trip at every size" {
    for (areas) |area| {
        const shown = touch.shownIn(pane.Layout.of(area), width, height);
        const first = touch.toPanel(shown, width, height, shown.x, shown.y);
        try std.testing.expectEqual(touch.Point{ .x = 0, .y = 0 }, first);
        const last = touch.toPanel(shown, width, height, shown.x + shown.w - 1, shown.y + shown.h - 1);
        try std.testing.expectEqual(touch.Point{ .x = width - 1, .y = height - 1 }, last);
        const mid = touch.toPanel(shown, width, height, shown.x + @divTrunc(shown.w, 2), shown.y + @divTrunc(shown.h, 2));
        try std.testing.expect(within(mid.x, width / 2, @divTrunc(width, @as(u32, @intCast(shown.w))) + 1));
        try std.testing.expect(within(mid.y, height / 2, @divTrunc(height, @as(u32, @intCast(shown.h))) + 1));
    }
}

test "each switch's centre hits it at every size" {
    for (areas) |area| {
        const parts = pane.Layout.of(area);
        for (parts.switches, 0..) |button, index| {
            const x = button.x + @divTrunc(button.w, 2);
            const y = button.y + @divTrunc(button.h, 2);
            try std.testing.expectEqual(@as(?usize, index), parts.hit(x, y));
        }
    }
}

test "a press in a letterbox bar lands on no panel pixel" {
    for (areas) |area| {
        const parts = pane.Layout.of(area);
        const shown = touch.shownIn(parts, width, height);
        if (shown.h < parts.panel.h) {
            try std.testing.expect(!shown.contains(shown.x + 1, parts.panel.y));
        }
        if (shown.w < parts.panel.w) {
            try std.testing.expect(!shown.contains(parts.panel.x, shown.y + 1));
        }
        var drag: touch.Drag = .{};
        drag.down(shown, width, height, shown.x - 1, shown.y - 1, 0);
        try std.testing.expect(drag.start == null);
    }
}

test "the panel is sampled nearest only at whole-number scales" {
    try std.testing.expect(pane.wholeScale(.{ .x = 0, .y = 0, .w = 1024, .h = 600 }, width, height));
    try std.testing.expect(pane.wholeScale(.{ .x = 5, .y = 5, .w = 2048, .h = 1200 }, width, height));
    try std.testing.expect(!pane.wholeScale(.{ .x = 0, .y = 0, .w = 512, .h = 300 }, width, height));
    try std.testing.expect(!pane.wholeScale(.{ .x = 0, .y = 0, .w = 1536, .h = 900 }, width, height));
    try std.testing.expect(!pane.wholeScale(.{ .x = 0, .y = 0, .w = 2048, .h = 600 }, width, height));
}
