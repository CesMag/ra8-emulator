//! The app shell's pane layout (RA8EMU-754, slice 1 of RA8EMU-201): a tree
//! of splits whose leaves are panes, each bound to a core from day one so
//! dual-core views need no new model. Solving the tree for a window gives
//! every pane's rect and every splitter's gutter; dragging a gutter moves
//! its split, clamped so neither side drops under the minimum pane size.
const std = @import("std");
const draw_list = @import("ra8_render").draw_list;

pub const Rect = draw_list.Rect;
pub const Index = u16;

/// The width of the gap a splitter takes between its two sides.
pub const gutter: i32 = 4;
/// No drag shrinks a pane below this on the split's axis.
pub const min_size: i32 = 48;

pub const Core = enum { cpu0, cpu1 };
pub const Kind = enum { empty, board, console, camera, devices, registers, memory, disasm, stack };
/// `across` places the two sides left and right; `down` stacks them.
pub const Axis = enum { across, down };

pub const Pane = struct { kind: Kind, core: Core };
pub const Split = struct { axis: Axis, ratio: f32, first: Index, second: Index };
pub const Body = union(enum) { leaf: Pane, split: Split, free };
pub const Node = struct { parent: ?Index = null, body: Body };

/// A pane's place in a solved layout.
pub const Placed = struct { index: Index, area: Rect };
/// A splitter's place: its own gap and the area its split divides.
pub const Gutter = struct { split: Index, area: Rect, whole: Rect };

pub const Solved = struct {
    panes: std.ArrayListUnmanaged(Placed) = .empty,
    gutters: std.ArrayListUnmanaged(Gutter) = .empty,

    pub fn deinit(self: *Solved, allocator: std.mem.Allocator) void {
        self.panes.deinit(allocator);
        self.gutters.deinit(allocator);
    }

    /// The splitter under a point, if any.
    pub fn hit(self: *const Solved, x: i32, y: i32) ?Gutter {
        for (self.gutters.items) |found| if (found.area.contains(x, y)) return found;
        return null;
    }
};

pub const Layout = struct {
    allocator: std.mem.Allocator,
    nodes: std.ArrayListUnmanaged(Node) = .empty,
    root: Index = 0,

    /// A layout of one pane.
    pub fn init(allocator: std.mem.Allocator, only: Pane) !Layout {
        var self = Layout{ .allocator = allocator };
        _ = try self.add(.{ .body = .{ .leaf = only } });
        return self;
    }

    pub fn deinit(self: *Layout) void {
        self.nodes.deinit(self.allocator);
    }

    pub fn node(self: *const Layout, index: Index) Node {
        return self.nodes.items[index];
    }

    pub fn pane(self: *const Layout, index: Index) ?Pane {
        return switch (self.nodes.items[index].body) {
            .leaf => |found| found,
            else => null,
        };
    }

    /// Splits the leaf at `index` in half along `axis`: the old pane keeps
    /// the first side and `added` takes the second. Returns the new pane.
    pub fn split(self: *Layout, index: Index, axis: Axis, added: Pane) !Index {
        const old = self.pane(index) orelse return error.NotAPane;
        const first = try self.add(.{ .parent = index, .body = .{ .leaf = old } });
        const second = try self.add(.{ .parent = index, .body = .{ .leaf = added } });
        self.nodes.items[index].body = .{ .split = .{ .axis = axis, .ratio = 0.5, .first = first, .second = second } };
        return second;
    }

    /// Closes the pane at `index`; its sibling takes the whole split. The
    /// last pane is never removed, only emptied.
    pub fn close(self: *Layout, index: Index) !void {
        if (self.pane(index) == null) return error.NotAPane;
        const parent = self.nodes.items[index].parent orelse {
            self.nodes.items[index].body.leaf.kind = .empty;
            return;
        };
        const halves = self.nodes.items[parent].body.split;
        const sibling = if (halves.first == index) halves.second else halves.first;
        const kept = self.nodes.items[sibling].body;
        self.nodes.items[parent].body = kept;
        if (kept == .split) {
            self.nodes.items[kept.split.first].parent = parent;
            self.nodes.items[kept.split.second].parent = parent;
        }
        self.nodes.items[index] = .{ .body = .free };
        self.nodes.items[sibling] = .{ .body = .free };
    }

    pub fn rebind(self: *Layout, index: Index, core: Core) !void {
        if (self.pane(index) == null) return error.NotAPane;
        self.nodes.items[index].body.leaf.core = core;
    }

    pub fn setKind(self: *Layout, index: Index, kind: Kind) !void {
        if (self.pane(index) == null) return error.NotAPane;
        self.nodes.items[index].body.leaf.kind = kind;
    }

    /// Every pane's rect and every gutter for a window of `area`, panes in
    /// depth-first order, first side before second.
    pub fn solve(self: *const Layout, allocator: std.mem.Allocator, area: Rect) !Solved {
        var solved = Solved{};
        errdefer solved.deinit(allocator);
        try self.place(allocator, self.root, area, &solved);
        return solved;
    }

    /// Moves the split under `found` so its gutter sits at `at` (x for an
    /// across split, y for a down one), clamped to the minimum pane size.
    pub fn drag(self: *Layout, found: Gutter, at: i32) void {
        const halves = &self.nodes.items[found.split].body.split;
        const start = if (halves.axis == .across) found.whole.x else found.whole.y;
        const usable = span(found.whole, halves.axis) - gutter;
        if (usable <= 0) return;
        const wanted = clampFirst(at - start - @divTrunc(gutter, 2), usable);
        halves.ratio = @as(f32, @floatFromInt(wanted)) / @as(f32, @floatFromInt(usable));
    }

    fn place(self: *const Layout, allocator: std.mem.Allocator, index: Index, area: Rect, solved: *Solved) !void {
        switch (self.nodes.items[index].body) {
            .leaf => try solved.panes.append(allocator, .{ .index = index, .area = area }),
            .split => |halves| {
                const parts = divide(area, halves.axis, halves.ratio);
                try self.place(allocator, halves.first, parts.first, solved);
                try solved.gutters.append(allocator, .{ .split = index, .area = parts.gap, .whole = area });
                try self.place(allocator, halves.second, parts.second, solved);
            },
            .free => unreachable,
        }
    }

    fn add(self: *Layout, value: Node) !Index {
        for (self.nodes.items, 0..) |*slot, at| {
            if (slot.body != .free) continue;
            slot.* = value;
            return @intCast(at);
        }
        try self.nodes.append(self.allocator, value);
        return @intCast(self.nodes.items.len - 1);
    }
};

/// The two sides of `area` and the gap between them.
pub fn divide(area: Rect, axis: Axis, ratio: f32) struct { first: Rect, gap: Rect, second: Rect } {
    const usable = @max(0, span(area, axis) - gutter);
    const share: i32 = @intFromFloat(@round(@as(f32, @floatFromInt(usable)) * ratio));
    const first = clampFirst(share, usable);
    const second = usable - first;
    const gap = @min(gutter, span(area, axis));
    return switch (axis) {
        .across => .{
            .first = .{ .x = area.x, .y = area.y, .w = first, .h = area.h },
            .gap = .{ .x = area.x + first, .y = area.y, .w = gap, .h = area.h },
            .second = .{ .x = area.x + first + gap, .y = area.y, .w = second, .h = area.h },
        },
        .down => .{
            .first = .{ .x = area.x, .y = area.y, .w = area.w, .h = first },
            .gap = .{ .x = area.x, .y = area.y + first, .w = area.w, .h = gap },
            .second = .{ .x = area.x, .y = area.y + first + gap, .w = area.w, .h = second },
        },
    };
}

/// The first side's size for `usable` pixels: at least `min_size` on each
/// side when there is room, else an even split.
fn clampFirst(wanted: i32, usable: i32) i32 {
    if (usable < 2 * min_size) return @divTrunc(usable, 2);
    return std.math.clamp(wanted, min_size, usable - min_size);
}

fn span(area: Rect, axis: Axis) i32 {
    return if (axis == .across) area.w else area.h;
}

/// The starting two-core layout: CPU0's deck on the left as four quadrants
/// (board over disassembly, registers over console), CPU1's deck on the
/// right with the devices over its console. RA8EMU-199 decides the real
/// dual-core layout; this only seeds one.
pub fn twoCore(allocator: std.mem.Allocator) !Layout {
    var layout = try Layout.init(allocator, .{ .kind = .board, .core = .cpu0 });
    errdefer layout.deinit();
    const cpu1_deck = try layout.split(layout.root, .across, .{ .kind = .devices, .core = .cpu1 });
    const cpu0_deck = layout.node(layout.root).body.split.first;
    const right = try layout.split(cpu0_deck, .across, .{ .kind = .registers, .core = .cpu0 });
    const left = layout.node(cpu0_deck).body.split.first;
    _ = try layout.split(left, .down, .{ .kind = .disasm, .core = .cpu0 });
    _ = try layout.split(right, .down, .{ .kind = .console, .core = .cpu0 });
    _ = try layout.split(cpu1_deck, .down, .{ .kind = .console, .core = .cpu1 });
    layout.nodes.items[layout.root].body.split.ratio = 0.7;
    layout.nodes.items[cpu0_deck].body.split.ratio = 0.55;
    layout.nodes.items[left].body.split.ratio = 0.55;
    layout.nodes.items[right].body.split.ratio = 0.6;
    layout.nodes.items[cpu1_deck].body.split.ratio = 0.65;
    return layout;
}
