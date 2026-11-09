//! Host tests for the shell's saved pane layout (RA8EMU-958): a tree
//! round-trips through the store's text, a corrupt or missing save is the
//! default layout, and restore swaps the saved tree in whole.
const std = @import("std");
const ra8 = @import("ra8");
const gui_app = @import("gui_app");
const pane_layout = gui_app.pane_layout;
const layout_store = gui_app.shell.layout_store;

/// The two trees hold the same shape. Node ids are internal (the parser
/// numbers children before their parent), so only the tree is compared.
fn compareTree(a: *const pane_layout.Layout, a_index: pane_layout.Index, b: *const pane_layout.Layout, b_index: pane_layout.Index, depth: u8) !void {
    try std.testing.expect(depth <= 8);
    const a_node = a.nodes.items[a_index];
    const b_node = b.nodes.items[b_index];
    try std.testing.expect(std.meta.activeTag(a_node.body) == std.meta.activeTag(b_node.body));
    try std.testing.expectEqual(a_node.parent != null, b_node.parent != null);
    switch (a_node.body) {
        .leaf, .free => {},
        .split => |split| {
            const other = b_node.body.split;
            try std.testing.expectEqual(split.axis, other.axis);
            try std.testing.expectEqual(split.ratio, other.ratio);
            try compareTree(a, split.first, b, other.first, depth + 1);
            try compareTree(a, split.second, b, other.second, depth + 1);
        },
        .deck => |deck| {
            const other = b_node.body.deck;
            try std.testing.expectEqual(deck.active, other.active);
            try std.testing.expectEqual(deck.count, other.count);
            for (deck.children[0..deck.count], other.children[0..other.count]) |a_child, b_child| {
                try compareTree(a, a_child, b, b_child, depth + 1);
            }
        },
    }
}

test "a layout round-trips through the store's text" {
    const gpa = std.testing.allocator;
    var layout = try pane_layout.Layout.init(gpa, .{ .kind = .board, .core = .cpu0 });
    defer layout.deinit();
    // Build the shapes a session of use produces: a split, kinds.
    const added = try layout.split(layout.root, .across, .{ .kind = .registers, .core = .cpu1 });
    try layout.setKind(added, .disasm);
    var buf: [4096]u8 = undefined;
    const text = try layout_store.encode(&layout, &buf);
    var parsed = try layout_store.parse(text, gpa);
    defer parsed.deinit();
    try compareTree(&layout, layout.root, &parsed, parsed.root, 0);
}

test "a deck round-trips with its active child" {
    const gpa = std.testing.allocator;
    var layout = try pane_layout.Layout.init(gpa, .{ .kind = .board, .core = .cpu0 });
    defer layout.deinit();
    // Deck the root over its two halves, switch the shown tab.
    _ = try layout.split(layout.root, .down, .{ .kind = .memory, .core = .cpu0 });
    const halves = layout.node(layout.root).body.split;
    const children = [_]pane_layout.Index{ halves.first, halves.second };
    try layout.deck(layout.root, &children);
    var held = layout.deckAt(layout.root).?;
    held.active = 1;
    try layout.setDeck(layout.root, held);
    var buf: [4096]u8 = undefined;
    const text = try layout_store.encode(&layout, &buf);
    var parsed = try layout_store.parse(text, gpa);
    defer parsed.deinit();
    try compareTree(&layout, layout.root, &parsed, parsed.root, 0);
}

test "a corrupt save is refused, not a crash" {
    const gpa = std.testing.allocator;
    const bad = [_][]const u8{
        "",
        "banana",
        "leaf banana cpu0",
        "leaf registers atmega",
        "split across 3 leaf registers cpu0 leaf empty cpu0",
        "split down 0 leaf board cpu0 leaf board cpu0",
        "deck 9 2 leaf board cpu0 leaf board cpu0",
        "deck 0 5 leaf board cpu0 leaf board cpu0",
        "split across 0.5 leaf registers cpu0 leaf empty cpu0 trailing",
        "leaf registers",
    };
    for (bad) |bytes| {
        try std.testing.expectError(error.Corrupt, layout_store.parse(bytes, gpa));
    }
}

test "restore with no directory keeps the layout whole" {
    const gpa = std.testing.allocator;
    var layout = try pane_layout.twoCore(gpa);
    defer layout.deinit();
    var fresh = try pane_layout.twoCore(gpa);
    defer fresh.deinit();
    const store = layout_store.Store{ .io = std.testing.io, .allocator = gpa, .dir = null };
    store.restore(&layout);
    try compareTree(&layout, layout.root, &fresh, fresh.root, 0);
}

test "save writes the tree and restore reads it back" {
    const gpa = std.testing.allocator;
    // A scratch dir under the process cwd; the store joins it to the file.
    const dir = "ra8_layout_store_test_tmp";
    try std.Io.Dir.cwd().createDirPath(std.testing.io, dir);
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, dir) catch {};
    var layout = try pane_layout.Layout.init(gpa, .{ .kind = .board, .core = .cpu0 });
    defer layout.deinit();
    const added = try layout.split(layout.root, .across, .{ .kind = .console, .core = .cpu1 });
    try layout.setKind(added, .memory);
    const store = layout_store.Store{ .io = std.testing.io, .allocator = gpa, .dir = dir };
    store.save(&layout);
    var fresh = try pane_layout.Layout.init(gpa, .{ .kind = .board, .core = .cpu0 });
    defer fresh.deinit();
    store.restore(&fresh);
    try compareTree(&layout, layout.root, &fresh, fresh.root, 0);
}

test "a corrupt file leaves the layout untouched" {
    const gpa = std.testing.allocator;
    // A scratch dir under the process cwd; the store joins it to the file.
    const dir = "ra8_layout_store_test_tmp";
    try std.Io.Dir.cwd().createDirPath(std.testing.io, dir);
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, dir) catch {};
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = dir ++ "/" ++ layout_store.file_name, .data = "banana" });
    var layout = try pane_layout.twoCore(gpa);
    defer layout.deinit();
    const before = layout.node(layout.root).body;
    const store = layout_store.Store{ .io = std.testing.io, .allocator = gpa, .dir = dir };
    store.restore(&layout);
    try std.testing.expectEqual(before, layout.node(layout.root).body);
    try std.testing.expect(layout.pane(layout.root) == null);
}

test "metrics panes retain kind core and deck selection after serialization" {
    const gpa = std.testing.allocator;
    var layout = try pane_layout.Layout.init(gpa, .{ .kind = .host_metrics, .core = .cpu0 });
    defer layout.deinit();
    _ = try layout.split(layout.root, .across, .{ .kind = .device_metrics, .core = .cpu1 });
    const halves = layout.node(layout.root).body.split;
    try layout.deck(layout.root, &.{ halves.first, halves.second });
    var deck = layout.deckAt(layout.root).?;
    deck.active = 1;
    try layout.setDeck(layout.root, deck);
    var buf: [4096]u8 = undefined;
    var restored = try layout_store.parse(try layout_store.encode(&layout, &buf), gpa);
    defer restored.deinit();
    const saved = restored.deckAt(restored.root).?;
    try std.testing.expectEqual(@as(u8, 1), saved.active);
    try std.testing.expectEqual(pane_layout.Kind.host_metrics, restored.pane(saved.children[0]).?.kind);
    try std.testing.expectEqual(pane_layout.Kind.device_metrics, restored.pane(saved.children[1]).?.kind);
    try std.testing.expectEqual(pane_layout.Core.cpu1, restored.pane(saved.children[1]).?.core);
    var solved = try restored.solve(gpa, .{ .x = 0, .y = 0, .w = 640, .h = 480 });
    defer solved.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 1), solved.panes.items.len);
    try std.testing.expectEqual(saved.children[1], solved.panes.items[0].index);
}
