//! Changing what a shell leaf shows from its title bar (RA8EMU-800). A left
//! press on a leaf's title steps its kind to the next one (empty, board,
//! console, camera, devices, then round to empty), keeping the core it is
//! bound to, so any leaf can become the camera picker (RA8EMU-796) or any
//! other pane without a new layout.
const std = @import("std");
const pane_layout = @import("../ui/pane_layout.zig");
const shell_frame = @import("../ui/shell/frame.zig");

const Kind = pane_layout.Kind;

/// The kind after `kind`, wrapping from the last back to the first.
pub fn nextKind(kind: Kind) Kind {
    const kinds = std.enums.values(Kind);
    // Count in usize: the enum's tag is only as wide as its kinds, so the
    // last kind's index plus one does not fit in it.
    const at = @as(usize, @backingInt(kind)) + 1;
    return if (at == kinds.len) kinds[0] else @fromBackingInt(@intCast(at));
}

/// The leaf whose title bar holds (`x`, `y`), or null.
pub fn titleAt(layout: *const pane_layout.Layout, solved: *const pane_layout.Solved, x: i32, y: i32) ?pane_layout.Index {
    for (solved.panes.items) |placed| {
        if (layout.pane(placed.index) == null) continue;
        if (shell_frame.titleOf(placed.area).contains(x, y)) return placed.index;
    }
    return null;
}

/// Step the kind of the leaf titled at (`x`, `y`). A press on a deck
/// child's tab row instead switches the shown child (RA8EMU-958). Returns
/// whether a title took the press.
pub fn titlePress(layout: *pane_layout.Layout, solved: *const pane_layout.Solved, x: i32, y: i32) bool {
    const index = titleAt(layout, solved, x, y) orelse return false;
    const pane = layout.pane(index) orelse return false;
    if (pane.kind == .device_metrics) {
        const area = placedAt(solved, index) orelse return false;
        if (shell_frame.coreToggle(shell_frame.titleOf(area)).contains(x, y)) {
            layout.nodes.items[index].body.leaf.core = if (pane.core == .cpu0) .cpu1 else .cpu0;
            return true;
        }
    }
    if (layout.deckParent(index)) |parent| return deckPress(layout, solved, index, parent, x, y);
    layout.setKind(index, nextKind(pane.kind)) catch return false;
    return true;
}

/// A press on a deck child's tab row: over the tab that holds the point,
/// show that child; anywhere else on the row, take the press anyway.
fn deckPress(layout: *pane_layout.Layout, solved: *const pane_layout.Solved, child: pane_layout.Index, parent: pane_layout.Index, x: i32, y: i32) bool {
    const deck = layout.deckAt(parent) orelse return false;
    // Only the active child is placed, and it covers the deck's area.
    const area = placedAt(solved, child) orelse return false;
    const title = shell_frame.titleOf(area);
    var panes: [pane_layout.max_deck]pane_layout.Pane = undefined;
    for (0..deck.count) |at| panes[at] = layout.pane(deck.children[at]) orelse .{ .kind = .empty, .core = .cpu0 };
    var shown = deck;
    for (0..deck.count) |at| {
        const cell = shell_frame.tabAt(title, panes[0..deck.count], at) orelse continue;
        if (cell.contains(x, y)) {
            shown.active = @intCast(at);
            layout.setDeck(parent, shown) catch return false;
            return true;
        }
    }
    return true;
}

/// The area `solved` gave the node at `index`, when it was placed.
fn placedAt(solved: *const pane_layout.Solved, index: pane_layout.Index) ?pane_layout.Rect {
    for (solved.panes.items) |placed| if (placed.index == index) return placed.area;
    return null;
}

/// A tab drag under way: the deck it came from and which child left it.
pub const Drag = struct { parent: pane_layout.Index, child: u8 };

/// The drag a press on a deck's tab row holds, or null when the press was
/// not on a deck's tab row.
pub fn dragFrom(layout: *const pane_layout.Layout, solved: *const pane_layout.Solved, x: i32, y: i32) ?Drag {
    const index = titleAt(layout, solved, x, y) orelse return null;
    if (layout.pane(index).?.kind == .device_metrics) {
        const area = placedAt(solved, index) orelse return null;
        if (shell_frame.coreToggle(shell_frame.titleOf(area)).contains(x, y)) return null;
    }
    const parent = layout.deckParent(index) orelse return null;
    const deck = layout.deckAt(parent) orelse return null;
    // The leaf the row lives on is the active child; its area is the deck's.
    const area = placedAt(solved, index) orelse return null;
    const title = shell_frame.titleOf(area);
    var panes: [pane_layout.max_deck]pane_layout.Pane = undefined;
    for (0..deck.count) |at| panes[at] = layout.pane(deck.children[at]) orelse .{ .kind = .empty, .core = .cpu0 };
    for (0..deck.count) |at| {
        const cell = shell_frame.tabAt(title, panes[0..deck.count], at) orelse continue;
        if (cell.contains(x, y)) return .{ .parent = parent, .child = @intCast(at) };
    }
    return null;
}

/// A released tab drag: letting go over another pane splits the deck side
/// by side, the dragged view on the side it let go toward. Returns whether
/// the layout changed.
pub fn dragDrop(layout: *pane_layout.Layout, solved: *const pane_layout.Solved, drag: Drag, x: i32, y: i32) bool {
    const deck = layout.deckAt(drag.parent) orelse return false;
    const home = placedAt(solved, deck.children[deck.active]) orelse return false;
    for (solved.panes.items) |placed| {
        if (std.meta.eql(placed.area, home)) continue;
        if (!placed.area.contains(x, y)) continue;
        _ = layout.splitDeck(drag.parent, drag.child, x < home.x + @divTrunc(home.w, 2)) catch return false;
        return true;
    }
    return false;
}

/// The shell's tab-drag state: a press on a deck's tab row records a drag
/// candidate and takes the switch as before; its release splits the deck
/// when it let go over another pane.
pub const Tracker = struct {
    drag: ?Drag = null,

    pub fn press(self: *Tracker, layout: *pane_layout.Layout, solved: *const pane_layout.Solved, x: i32, y: i32) bool {
        self.drag = dragFrom(layout, solved, x, y);
        return titlePress(layout, solved, x, y);
    }

    /// The left button came up: a held tab drag that let go over another
    /// pane splits its deck side by side. Returns whether the layout changed.
    pub fn release(self: *Tracker, layout: *pane_layout.Layout, solved: *const pane_layout.Solved, x: i32, y: i32) bool {
        const drag = self.drag orelse return false;
        self.drag = null;
        return dragDrop(layout, solved, drag, x, y);
    }
};
