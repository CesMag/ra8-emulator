//! Aim a tap at one part of a published widget (RA8EMU-731).
//!
//! Uses only what the ra8_widget debug tree publishes for the widget: its
//! name, rect and state. The rules match ra8-ui's host aiming, so a flow taps
//! the same pixel through the harness as it did through its stand-in.
const std = @import("std");
const widget_tree = @import("widget_tree.zig");

const Widget = widget_tree.Widget;

pub const Error = error{ WidgetNotFound, AmbiguousWidget, NoSuchPart, BadPart, InvalidWidgetRect };

/// Which part of a widget to touch.
pub const Part = union(enum) {
    /// The middle of the widget.
    centre,
    /// One cell of a segmented control or nav bar, counted from the left.
    cell: u16,
    /// One row of a list, counted from the top.
    row: u16,
    /// A spot inside the widget, as percentages of its width and height.
    at: struct { x_pct: u8, y_pct: u8 },
    /// A pager's previous (left third) or next (right third) control.
    previous,
    next,
};

pub const Point = struct { x: u16, y: u16 };

/// The one widget published as `name`.
pub fn find(tree: []const Widget, name: []const u8) Error!*const Widget {
    var found: ?*const Widget = null;
    for (tree) |*widget| {
        if (!std.mem.eql(u8, widget.nameSlice(), name)) continue;
        if (found != null) return error.AmbiguousWidget;
        found = widget;
    }
    return found orelse error.WidgetNotFound;
}

/// The panel pixel for `part` of `widget`.
pub fn aim(widget: *const Widget, part: Part) Error!Point {
    const r = widget.rect;
    if (r.w <= 0 or r.h <= 0) return error.InvalidWidgetRect;
    const x: i64 = r.x;
    const y: i64 = r.y;
    const w: i64 = r.w;
    const h: i64 = r.h;
    const mid_x = x + @divTrunc(w, 2);
    const mid_y = y + @divTrunc(h, 2);
    return switch (part) {
        .centre => panel(mid_x, mid_y),
        .cell => |index| {
            const count = try field(widget, "n");
            if (index >= count) return error.NoSuchPart;
            return panel(x + @divTrunc((2 * @as(i64, index) + 1) * w, 2 * count), mid_y);
        },
        .row => |index| {
            const count = try field(widget, "n");
            const height = try field(widget, "h");
            if (index >= count) return error.NoSuchPart;
            return panel(mid_x, y + @as(i64, index) * height + @divTrunc(height, 2));
        },
        .at => |spot| {
            if (spot.x_pct > 100 or spot.y_pct > 100) return error.BadPart;
            return panel(x + @divTrunc(w * spot.x_pct, 100), y + @divTrunc(h * spot.y_pct, 100));
        },
        .previous => panel(x + @divTrunc(w, 6), mid_y),
        .next => panel(x + @divTrunc(5 * w, 6), mid_y),
    };
}

/// The positive number after `key=` in the widget's state words.
fn field(widget: *const Widget, key: []const u8) Error!i64 {
    var words = std.mem.tokenizeScalar(u8, widget.stateSlice(), ' ');
    while (words.next()) |word| {
        if (word.len <= key.len or !std.mem.startsWith(u8, word, key) or word[key.len] != '=') continue;
        const value = std.fmt.parseInt(i64, word[key.len + 1 ..], 10) catch return error.BadPart;
        if (value <= 0) return error.BadPart;
        return value;
    }
    return error.BadPart;
}

fn panel(x: i64, y: i64) Error!Point {
    const limit = std.math.maxInt(u16);
    if (x < 0 or x > limit or y < 0 or y > limit) return error.InvalidWidgetRect;
    return .{ .x = @intCast(x), .y = @intCast(y) };
}
