//! Covers src/interfaces/gui/window_size.zig: the opening size follows
//! the screen inside the minimum, the UI scale is a whole number, and the
//! layout size is the drawable divided by it (RA8EMU-966).
const std = @import("std");
const gui_app = @import("gui_app");
const window_size = gui_app.window.size;

test "a new window opens at most of the screen, never under the minimum or over the screen" {
    const laptop = window_size.initial(.{ .width = 1440, .height = 875 });
    try std.testing.expectEqual(@as(u32, 1152), laptop.width);
    try std.testing.expectEqual(@as(u32, 700), laptop.height);
    const big = window_size.initial(.{ .width = 3840, .height = 2110 });
    try std.testing.expectEqual(@as(u32, 3072), big.width);
    try std.testing.expectEqual(@as(u32, 1688), big.height);
    const small = window_size.initial(.{ .width = 900, .height = 560 });
    try std.testing.expectEqual(window_size.min.width, small.width);
    try std.testing.expectEqual(window_size.min.height, small.height);
    const tiny = window_size.initial(.{ .width = 640, .height = 480 });
    try std.testing.expectEqual(@as(u32, 640), tiny.width);
    try std.testing.expectEqual(@as(u32, 480), tiny.height);
}

test "an unknown screen opens at the minimum" {
    const none = window_size.initial(.{ .width = 0, .height = 0 });
    try std.testing.expectEqual(window_size.min.width, none.width);
    try std.testing.expectEqual(window_size.min.height, none.height);
}

test "the UI scale rounds the display scale to a whole number of at least one" {
    try std.testing.expectEqual(@as(u32, 1), window_size.uiScale(1.0));
    try std.testing.expectEqual(@as(u32, 1), window_size.uiScale(1.25));
    try std.testing.expectEqual(@as(u32, 2), window_size.uiScale(1.5));
    try std.testing.expectEqual(@as(u32, 2), window_size.uiScale(2.0));
    try std.testing.expectEqual(@as(u32, 3), window_size.uiScale(3.0));
    try std.testing.expectEqual(@as(u32, 1), window_size.uiScale(0));
    try std.testing.expectEqual(@as(u32, 1), window_size.uiScale(-2));
    try std.testing.expectEqual(@as(u32, 1), window_size.uiScale(std.math.nan(f32)));
    try std.testing.expectEqual(@as(u32, 1), window_size.uiScale(std.math.inf(f32)));
}

test "the layout size is the drawable divided by the UI scale" {
    const retina = window_size.points(.{ .width = 2880, .height = 1750 }, 2);
    try std.testing.expectEqual(@as(u32, 1440), retina.width);
    try std.testing.expectEqual(@as(u32, 875), retina.height);
    const odd = window_size.points(.{ .width = 1001, .height = 601 }, 2);
    try std.testing.expectEqual(@as(u32, 500), odd.width);
    const zero = window_size.points(.{ .width = 800, .height = 500 }, 0);
    try std.testing.expectEqual(@as(u32, 800), zero.width);
}
