//! Covers src/interfaces/gui/ui/pane_layout.zig: solved panes and gutters tile the window
//! exactly at several sizes, a gutter drag moves its split and clamps to
//! the minimum pane size, split and close keep the tree valid, a pane's
//! core can be rebound, and the two-core seed layout has both cores.
const std = @import("std");
const gui_app = @import("gui_app");
const layout_mod = gui_app.pane_layout;
const Layout = layout_mod.Layout;
const Rect = layout_mod.Rect;

const allocator = std.testing.allocator;

/// Panes plus gutters cover `area` once each: areas sum and nothing overlaps.
fn expectTiles(solved: *const layout_mod.Solved, area: Rect) !void {
    var rects = std.ArrayListUnmanaged(Rect).empty;
    defer rects.deinit(allocator);
    for (solved.panes.items) |placed| try rects.append(allocator, placed.area);
    for (solved.gutters.items) |found| try rects.append(allocator, found.area);
    var total: i64 = 0;
    for (rects.items, 0..) |rect, i| {
        try std.testing.expect(rect.w >= 0 and rect.h >= 0);
        try std.testing.expect(rect.intersect(area).w == rect.w and rect.intersect(area).h == rect.h);
        total += @as(i64, rect.w) * rect.h;
        for (rects.items[i + 1 ..]) |other| try std.testing.expect(rect.intersect(other).empty());
    }
    try std.testing.expectEqual(@as(i64, area.w) * area.h, total);
}

test "the two-core layout tiles the window exactly at several sizes" {
    var layout = try layout_mod.twoCore(allocator);
    defer layout.deinit();
    const sizes = [_][2]i32{ .{ 1280, 860 }, .{ 3840, 2160 }, .{ 641, 401 }, .{ 200, 150 } };
    for (sizes) |size| {
        const area = Rect{ .x = 0, .y = 0, .w = size[0], .h = size[1] };
        var solved = try layout.solve(allocator, area);
        defer solved.deinit(allocator);
        try std.testing.expectEqual(@as(usize, 4), solved.panes.items.len);
        try std.testing.expectEqual(@as(usize, 3), solved.gutters.items.len);
        try expectTiles(&solved, area);
    }
}

test "the two-core layout binds panes to both cores" {
    var layout = try layout_mod.twoCore(allocator);
    defer layout.deinit();
    var solved = try layout.solve(allocator, .{ .x = 0, .y = 0, .w = 1280, .h = 860 });
    defer solved.deinit(allocator);
    const want = [_]layout_mod.Pane{
        .{ .kind = .board, .core = .cpu0 },
        .{ .kind = .console, .core = .cpu0 },
        .{ .kind = .devices, .core = .cpu1 },
        .{ .kind = .console, .core = .cpu1 },
    };
    for (solved.panes.items, want) |placed, pane| try std.testing.expectEqual(pane, layout.pane(placed.index).?);
}

test "a gutter drag moves its split and clamps to the minimum pane size" {
    var layout = try Layout.init(allocator, .{ .kind = .board, .core = .cpu0 });
    defer layout.deinit();
    _ = try layout.split(layout.root, .across, .{ .kind = .console, .core = .cpu0 });
    const area = Rect{ .x = 10, .y = 0, .w = 404, .h = 300 };
    var solved = try layout.solve(allocator, area);
    defer solved.deinit(allocator);
    try std.testing.expectEqual(@as(i32, 200), solved.panes.items[0].area.w);
    const found = solved.hit(10 + 201, 50).?;
    layout.drag(found, 10 + 102);
    var moved = try layout.solve(allocator, area);
    defer moved.deinit(allocator);
    try std.testing.expectEqual(@as(i32, 100), moved.panes.items[0].area.w);
    layout.drag(found, 0);
    var low = try layout.solve(allocator, area);
    defer low.deinit(allocator);
    try std.testing.expectEqual(layout_mod.min_size, low.panes.items[0].area.w);
    layout.drag(found, 10_000);
    var high = try layout.solve(allocator, area);
    defer high.deinit(allocator);
    try std.testing.expectEqual(layout_mod.min_size, high.panes.items[1].area.w);
    try expectTiles(&high, area);
}

test "a point off every gutter hits nothing" {
    var layout = try layout_mod.twoCore(allocator);
    defer layout.deinit();
    var solved = try layout.solve(allocator, .{ .x = 0, .y = 0, .w = 1280, .h = 860 });
    defer solved.deinit(allocator);
    try std.testing.expect(solved.hit(5, 5) == null);
}

test "closing a pane gives its sibling the split and reuses the freed nodes" {
    var layout = try layout_mod.twoCore(allocator);
    defer layout.deinit();
    const area = Rect{ .x = 0, .y = 0, .w = 1280, .h = 860 };
    var before = try layout.solve(allocator, area);
    defer before.deinit(allocator);
    try layout.close(before.panes.items[1].index);
    var after = try layout.solve(allocator, area);
    defer after.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 3), after.panes.items.len);
    try std.testing.expectEqual(layout_mod.Kind.board, layout.pane(after.panes.items[0].index).?.kind);
    try std.testing.expectEqual(@as(i32, 0), after.panes.items[0].area.y);
    try std.testing.expectEqual(area.h, after.panes.items[0].area.h);
    try expectTiles(&after, area);
    const count = layout.nodes.items.len;
    _ = try layout.split(after.panes.items[0].index, .down, .{ .kind = .camera, .core = .cpu0 });
    try std.testing.expectEqual(count, layout.nodes.items.len);
}

test "closing a split's pane re-parents the sibling's children" {
    var layout = try Layout.init(allocator, .{ .kind = .board, .core = .cpu0 });
    defer layout.deinit();
    const right = try layout.split(layout.root, .across, .{ .kind = .console, .core = .cpu0 });
    _ = try layout.split(right, .down, .{ .kind = .devices, .core = .cpu1 });
    const left = layout.node(layout.root).body.split.first;
    try layout.close(left);
    const root = layout.node(layout.root).body.split;
    try std.testing.expectEqual(layout_mod.Axis.down, root.axis);
    try std.testing.expectEqual(@as(?layout_mod.Index, layout.root), layout.node(root.first).parent);
    try std.testing.expectEqual(@as(?layout_mod.Index, layout.root), layout.node(root.second).parent);
}

test "the last pane is emptied, not removed" {
    var layout = try Layout.init(allocator, .{ .kind = .board, .core = .cpu1 });
    defer layout.deinit();
    try layout.close(layout.root);
    try std.testing.expectEqual(layout_mod.Pane{ .kind = .empty, .core = .cpu1 }, layout.pane(layout.root).?);
}

test "a pane's core and kind can change, and a split is not a pane" {
    var layout = try Layout.init(allocator, .{ .kind = .board, .core = .cpu0 });
    defer layout.deinit();
    const added = try layout.split(layout.root, .down, .{ .kind = .empty, .core = .cpu0 });
    try layout.rebind(added, .cpu1);
    try layout.setKind(added, .console);
    try std.testing.expectEqual(layout_mod.Pane{ .kind = .console, .core = .cpu1 }, layout.pane(added).?);
    try std.testing.expectError(error.NotAPane, layout.rebind(layout.root, .cpu1));
    try std.testing.expectError(error.NotAPane, layout.close(layout.root));
}

test "a window too small for two minimum panes splits evenly" {
    const parts = layout_mod.divide(.{ .x = 0, .y = 0, .w = 60, .h = 40 }, .across, 0.9);
    try std.testing.expectEqual(@as(i32, 28), parts.first.w);
    try std.testing.expectEqual(@as(i32, 28), parts.second.w);
    try std.testing.expectEqual(@as(i32, 32), parts.second.x);
}
