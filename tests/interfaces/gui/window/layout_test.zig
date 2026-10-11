//! The two-core shell at the minimum window, a laptop-sized one and a 4K
//! one (RA8EMU-966): every pane keeps its minimum size, sits above the time
//! bar, and no two panes overlap, so nothing collapses or clips as the
//! window grows from smallest to fullscreen.
const std = @import("std");
const gui_app = @import("gui_app");
const pane_layout = gui_app.pane_layout;
const frame = gui_app.shell.frame;
const window_size = gui_app.window.size;

fn check(width: i32, height: i32) !void {
    const allocator = std.testing.allocator;
    var layout = try pane_layout.twoCore(allocator);
    defer layout.deinit();
    var solved = try frame.solve(&layout, allocator, width, height);
    defer solved.deinit(allocator);
    const room = frame.panesArea(width, height);
    try std.testing.expectEqual(@as(usize, 6), solved.panes.items.len);
    for (solved.panes.items, 0..) |placed, index| {
        const area = placed.area;
        try std.testing.expect(area.w >= pane_layout.min_size and area.h >= pane_layout.min_size);
        try std.testing.expect(area.h > frame.title_h);
        try std.testing.expect(area.x >= 0 and area.y >= 0);
        try std.testing.expect(area.x + area.w <= room.w and area.y + area.h <= room.h);
        for (solved.panes.items[index + 1 ..]) |other| {
            const shared = area.intersect(other.area);
            try std.testing.expect(shared.w <= 0 or shared.h <= 0);
        }
    }
}

test "every pane keeps its minimum and stays on screen at the minimum window" {
    try check(@intCast(window_size.min.width), @intCast(window_size.min.height));
}

test "every pane keeps its minimum and stays on screen at a laptop-sized window" {
    try check(1280, 860);
}

test "every pane keeps its minimum and stays on screen at 4K" {
    try check(3840, 2160);
}

test "a Retina 4K screen lays out at its point size" {
    const at = window_size.points(.{ .width = 3840, .height = 2160 }, window_size.uiScale(2.0));
    try check(@intCast(at.width), @intCast(at.height));
}
