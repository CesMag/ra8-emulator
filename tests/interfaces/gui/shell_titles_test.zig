//! Host tests for changing a shell leaf's kind from its title bar
//! (RA8EMU-800): the kind cycle, a press on a title stepping only that leaf
//! and keeping its core, and a press off every title doing nothing.
const std = @import("std");
const gui_app = @import("gui_app");
const pane_layout = gui_app.pane_layout;
const frame = gui_app.shell_frame;
const titles = gui_app.shell_titles;

test "the kinds cycle from empty through disassembly and back to empty" {
    try std.testing.expectEqual(pane_layout.Kind.board, titles.nextKind(.empty));
    try std.testing.expectEqual(pane_layout.Kind.console, titles.nextKind(.board));
    try std.testing.expectEqual(pane_layout.Kind.camera, titles.nextKind(.console));
    try std.testing.expectEqual(pane_layout.Kind.devices, titles.nextKind(.camera));
    try std.testing.expectEqual(pane_layout.Kind.registers, titles.nextKind(.devices));
    try std.testing.expectEqual(pane_layout.Kind.memory, titles.nextKind(.registers));
    try std.testing.expectEqual(pane_layout.Kind.disasm, titles.nextKind(.memory));
    try std.testing.expectEqual(pane_layout.Kind.empty, titles.nextKind(.disasm));
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
    try std.testing.expect(titles.press(&layout, &solved, title.x + 1, title.y + 1));
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
    try std.testing.expect(!titles.press(&layout, &solved, body.x + 1, body.y + 1));
    const gap = solved.gutters.items[0].area;
    try std.testing.expect(!titles.press(&layout, &solved, gap.x, gap.y + 1));
    try std.testing.expectEqual(@as(?pane_layout.Index, null), titles.titleAt(&layout, &solved, body.x + 1, body.y + 1));
}
