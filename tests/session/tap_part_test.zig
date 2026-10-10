//! Host tests for aiming a tap at part of a published widget (RA8EMU-731).
const std = @import("std");
const ra8 = @import("ra8");
const tap_part = ra8.session.tap_part;
const widget_tree = ra8.session.widget_tree;

fn record(name: []const u8, state: []const u8, rect: widget_tree.Rect) widget_tree.Widget {
    var widget: widget_tree.Widget = .{ .name = @splat(0), .kind = @splat(0), .state = @splat(0), .rect = rect };
    @memcpy(widget.name[0..name.len], name);
    @memcpy(widget.state[0..state.len], state);
    return widget;
}

const bar = record("tabs", "sel=1 n=4", .{ .x = 0, .y = 1300, .w = 1072, .h = 100 });
const list = record("apps", "n=5 h=120", .{ .x = 40, .y = 200, .w = 1000, .h = 600 });
const pager = record("pager", "page=2", .{ .x = 0, .y = 1380, .w = 1072, .h = 60 });

fn expectPoint(expected: tap_part.Point, widget: *const widget_tree.Widget, part: tap_part.Part) !void {
    try std.testing.expectEqual(expected, try tap_part.aim(widget, part));
}

test "centre and cells split the published width by n" {
    try expectPoint(.{ .x = 536, .y = 1350 }, &bar, .centre);
    try expectPoint(.{ .x = 134, .y = 1350 }, &bar, .{ .cell = 0 });
    try expectPoint(.{ .x = 938, .y = 1350 }, &bar, .{ .cell = 3 });
    try std.testing.expectError(error.NoSuchPart, tap_part.aim(&bar, .{ .cell = 4 }));
}

test "rows step by the published row height from the top" {
    try expectPoint(.{ .x = 540, .y = 260 }, &list, .{ .row = 0 });
    try expectPoint(.{ .x = 540, .y = 740 }, &list, .{ .row = 4 });
    try std.testing.expectError(error.NoSuchPart, tap_part.aim(&list, .{ .row = 5 }));
    try std.testing.expectError(error.BadPart, tap_part.aim(&bar, .{ .row = 0 }));
}

test "pager controls are the outer thirds and at is a percentage of the rect" {
    try expectPoint(.{ .x = 178, .y = 1410 }, &pager, .previous);
    try expectPoint(.{ .x = 893, .y = 1410 }, &pager, .next);
    try expectPoint(.{ .x = 40, .y = 200 }, &list, .{ .at = .{ .x_pct = 0, .y_pct = 0 } });
    try expectPoint(.{ .x = 290, .y = 650 }, &list, .{ .at = .{ .x_pct = 25, .y_pct = 75 } });
    try std.testing.expectError(error.BadPart, tap_part.aim(&list, .{ .at = .{ .x_pct = 101, .y_pct = 0 } }));
}

test "a state without n, an empty rect and an off-panel point are refused" {
    try std.testing.expectError(error.BadPart, tap_part.aim(&pager, .{ .cell = 0 }));
    const zero = record("z", "n=0", .{ .x = 0, .y = 0, .w = 10, .h = 10 });
    try std.testing.expectError(error.BadPart, tap_part.aim(&zero, .{ .cell = 0 }));
    const empty = record("e", "", .{ .x = 0, .y = 0, .w = 0, .h = 10 });
    try std.testing.expectError(error.InvalidWidgetRect, tap_part.aim(&empty, .centre));
    const off = record("o", "", .{ .x = -50, .y = 0, .w = 20, .h = 10 });
    try std.testing.expectError(error.InvalidWidgetRect, tap_part.aim(&off, .centre));
}

test "find wants exactly one widget with the name" {
    const tree = [_]widget_tree.Widget{ bar, list, bar };
    try std.testing.expectEqual(&tree[1], try tap_part.find(&tree, "apps"));
    try std.testing.expectError(error.AmbiguousWidget, tap_part.find(&tree, "tabs"));
    try std.testing.expectError(error.WidgetNotFound, tap_part.find(&tree, "pager"));
}
