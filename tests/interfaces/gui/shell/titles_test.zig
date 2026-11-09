//! Host tests for changing a shell leaf's kind from its title bar
//! (RA8EMU-800): the kind cycle, a press on a title stepping only that leaf
//! and keeping its core, and a press off every title doing nothing.
const std = @import("std");
const gui_app = @import("gui_app");
const pane_layout = gui_app.pane_layout;
const frame = gui_app.shell.frame;
const titles = gui_app.shell.titles;

test "the kinds cycle from empty through the call stack and back to empty" {
    try std.testing.expectEqual(pane_layout.Kind.board, titles.nextKind(.empty));
    try std.testing.expectEqual(pane_layout.Kind.console, titles.nextKind(.board));
    try std.testing.expectEqual(pane_layout.Kind.camera, titles.nextKind(.console));
    try std.testing.expectEqual(pane_layout.Kind.devices, titles.nextKind(.camera));
    try std.testing.expectEqual(pane_layout.Kind.registers, titles.nextKind(.devices));
    try std.testing.expectEqual(pane_layout.Kind.memory, titles.nextKind(.registers));
    try std.testing.expectEqual(pane_layout.Kind.disasm, titles.nextKind(.memory));
    try std.testing.expectEqual(pane_layout.Kind.stack, titles.nextKind(.disasm));
    try std.testing.expectEqual(pane_layout.Kind.timeline, titles.nextKind(.stack));
    try std.testing.expectEqual(pane_layout.Kind.source, titles.nextKind(.timeline));
    try std.testing.expectEqual(pane_layout.Kind.locals, titles.nextKind(.source));
    try std.testing.expectEqual(pane_layout.Kind.map, titles.nextKind(.locals));
    try std.testing.expectEqual(pane_layout.Kind.diff, titles.nextKind(.map));
    try std.testing.expectEqual(pane_layout.Kind.branches, titles.nextKind(.diff));
    try std.testing.expectEqual(pane_layout.Kind.host_metrics, titles.nextKind(.branches));
    try std.testing.expectEqual(pane_layout.Kind.device_metrics, titles.nextKind(.host_metrics));
    try std.testing.expectEqual(pane_layout.Kind.empty, titles.nextKind(.device_metrics));
}

test "a press on a title steps that leaf's kind and keeps its core" {
    const gpa = std.testing.allocator;
    var layout = try pane_layout.twoCore(gpa);
    defer layout.deinit();
    var solved = try frame.solve(&layout, gpa, 480, 320);
    defer solved.deinit(gpa);
    var target: ?pane_layout.Placed = null;
    for (solved.panes.items) |placed| {
        const pane = layout.pane(placed.index) orelse continue;
        if (pane.kind == .console and pane.core == .cpu1) target = placed;
    }
    const placed = target.?;
    const title = frame.titleOf(placed.area);
    try std.testing.expect(titles.titlePress(&layout, &solved, title.x + 1, title.y + 1));
    const changed = layout.pane(placed.index).?;
    try std.testing.expectEqual(pane_layout.Kind.camera, changed.kind);
    try std.testing.expectEqual(pane_layout.Core.cpu1, changed.core);
    var cameras: usize = 0;
    for (solved.panes.items) |other| {
        if (layout.pane(other.index).?.kind == .camera) cameras += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), cameras);
}

test "a press in a body or a gutter is not a title's" {
    const gpa = std.testing.allocator;
    var layout = try pane_layout.twoCore(gpa);
    defer layout.deinit();
    var solved = try frame.solve(&layout, gpa, 480, 320);
    defer solved.deinit(gpa);
    const body = frame.bodyOf(solved.panes.items[0].area);
    try std.testing.expect(!titles.titlePress(&layout, &solved, body.x + 1, body.y + 1));
    const gap = solved.gutters.items[0].area;
    try std.testing.expect(!titles.titlePress(&layout, &solved, gap.x, gap.y + 1));
    try std.testing.expectEqual(@as(?pane_layout.Index, null), titles.titleAt(&layout, &solved, body.x + 1, body.y + 1));
}

test "device metrics core selector toggles without changing pane kind" {
    const gpa = std.testing.allocator;
    var layout = try pane_layout.Layout.init(gpa, .{ .kind = .device_metrics, .core = .cpu0 });
    defer layout.deinit();
    var solved = try layout.solve(gpa, .{ .x = 0, .y = 0, .w = 400, .h = 200 });
    defer solved.deinit(gpa);
    try std.testing.expect(titles.titlePress(&layout, &solved, 380, 5));
    try std.testing.expectEqual(pane_layout.Core.cpu1, layout.pane(layout.root).?.core);
    try std.testing.expectEqual(pane_layout.Kind.device_metrics, layout.pane(layout.root).?.kind);
}

test "device metrics deck core selector preserves active tab and does not drag" {
    const gpa = std.testing.allocator;
    var layout = try pane_layout.Layout.init(gpa, .{ .kind = .host_metrics, .core = .cpu0 });
    defer layout.deinit();
    _ = try layout.split(layout.root, .across, .{ .kind = .device_metrics, .core = .cpu0 });
    const halves = layout.node(layout.root).body.split;
    try layout.deck(layout.root, &.{ halves.first, halves.second });
    var deck = layout.deckAt(layout.root).?;
    deck.active = 1;
    try layout.setDeck(layout.root, deck);
    var solved = try layout.solve(gpa, .{ .x = 0, .y = 0, .w = 400, .h = 200 });
    defer solved.deinit(gpa);
    try std.testing.expect(titles.dragFrom(&layout, &solved, 380, 5) == null);
    try std.testing.expect(titles.titlePress(&layout, &solved, 380, 5));
    try std.testing.expectEqual(@as(u8, 1), layout.deckAt(layout.root).?.active);
    try std.testing.expectEqual(pane_layout.Core.cpu1, layout.pane(deck.children[1]).?.core);
    try std.testing.expect(titles.titlePress(&layout, &solved, 10, 5));
    try std.testing.expectEqual(@as(u8, 0), layout.deckAt(layout.root).?.active);
}
