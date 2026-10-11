//! The flame graph's model (RA8EMU-835): folded rows (`a;b;c count`, the
//! fold `ctl folded` and --profile-folded answer) merged into a frame tree.
//! Each node keeps its total (samples at or under it) and self (samples
//! that end on it). Children stay ordered by name, so the picture is the
//! same between refreshes. A box's span is its total's share of its
//! parent's span; zoom makes a node the root span, and back undoes it.
//! The filter is the core and thread the rows were asked for.
const std = @import("std");
const proto = @import("ra8_rpc").session.rpc;

pub const none: u32 = std.math.maxInt(u32);
/// The deepest zoom kept; a zoom past it drops the oldest step.
pub const max_zoom: usize = 32;

pub const Node = struct {
    name_at: u32,
    name_len: u32,
    parent: u32,
    first_child: u32 = none,
    next_sibling: u32 = none,
    depth: u32,
    total: u64 = 0,
    self: u64 = 0,
};

/// Which samples the rows hold: one core, and one thread or all.
pub const Filter = struct {
    core: proto.Core = .cpu0,
    thread: u32 = proto.all_threads,

    pub fn ask(self: Filter) proto.FoldedAsk {
        return .{ .core = self.core, .thread = self.thread };
    }
};

/// A box's horizontal extent in pixels: [x, x + w).
pub const Span = struct { x: i32, w: i32 };

pub const Model = struct {
    gpa: std.mem.Allocator,
    nodes: std.ArrayList(Node) = .empty,
    names: std.ArrayList(u8) = .empty,
    filter: Filter = .{},
    zooms: [max_zoom]u32 = undefined,
    zoom_len: usize = 0,

    pub fn init(gpa: std.mem.Allocator) Model {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Model) void {
        self.nodes.deinit(self.gpa);
        self.names.deinit(self.gpa);
    }

    /// Replace the tree with `rows`. A malformed line is skipped; zoom
    /// survives only while its node still names the same frame path.
    pub fn load(self: *Model, rows: []const u8) !void {
        self.nodes.clearRetainingCapacity();
        self.names.clearRetainingCapacity();
        self.zoom_len = 0;
        try self.nodes.append(self.gpa, .{ .name_at = 0, .name_len = 0, .parent = none, .depth = 0 });
        var lines = std.mem.tokenizeScalar(u8, rows, '\n');
        while (lines.next()) |line| try self.addLine(line);
    }

    fn addLine(self: *Model, line: []const u8) !void {
        const gap = std.mem.lastIndexOfScalar(u8, line, ' ') orelse return;
        const count = std.fmt.parseInt(u64, line[gap + 1 ..], 10) catch return;
        if (gap == 0) return;
        var at: u32 = 0;
        self.nodes.items[0].total += count;
        var frames = std.mem.splitScalar(u8, line[0..gap], ';');
        while (frames.next()) |frame| {
            if (frame.len == 0) continue;
            at = try self.child(at, frame);
            self.nodes.items[at].total += count;
        }
        self.nodes.items[at].self += count;
    }

    /// `parent`'s child called `name`, inserted in name order when new.
    fn child(self: *Model, parent: u32, called: []const u8) !u32 {
        var before: u32 = none;
        var at = self.nodes.items[parent].first_child;
        while (at != none) : (at = self.nodes.items[at].next_sibling) {
            switch (std.mem.order(u8, self.name(at), called)) {
                .eq => return at,
                .gt => break,
                .lt => before = at,
            }
        }
        const made: u32 = @intCast(self.nodes.items.len);
        const name_at: u32 = @intCast(self.names.items.len);
        try self.names.appendSlice(self.gpa, called);
        try self.nodes.append(self.gpa, .{ .name_at = name_at, .name_len = @intCast(called.len), .parent = parent, .depth = self.nodes.items[parent].depth + 1, .next_sibling = at });
        if (before == none) self.nodes.items[parent].first_child = made else self.nodes.items[before].next_sibling = made;
        return made;
    }

    pub fn name(self: *const Model, node: u32) []const u8 {
        const n = self.nodes.items[node];
        return self.names.items[n.name_at..][0..n.name_len];
    }

    pub fn get(self: *const Model, node: u32) Node {
        return self.nodes.items[node];
    }

    /// The node drawn as the full-width root: the last zoom, else the tree.
    pub fn root(self: *const Model) u32 {
        return if (self.zoom_len == 0) 0 else self.zooms[self.zoom_len - 1];
    }

    /// Samples under the root span, the 100% the pane's percentages use.
    pub fn window(self: *const Model) u64 {
        if (self.nodes.items.len == 0) return 0;
        return self.nodes.items[self.root()].total;
    }

    /// Make `node` the root span. Zooming into the root does nothing.
    pub fn zoom(self: *Model, node: u32) void {
        if (node >= self.nodes.items.len or node == self.root()) return;
        if (self.zoom_len == max_zoom) {
            std.mem.copyForwards(u32, self.zooms[0 .. max_zoom - 1], self.zooms[1..]);
            self.zoom_len -= 1;
        }
        self.zooms[self.zoom_len] = node;
        self.zoom_len += 1;
    }

    /// Undo the last zoom; false when there was none.
    pub fn back(self: *Model) bool {
        if (self.zoom_len == 0) return false;
        self.zoom_len -= 1;
        return true;
    }

    /// Choose another core or thread. The rows then describe the old one,
    /// so the tree empties until the next load; true when it changed.
    pub fn choose(self: *Model, filter: Filter) bool {
        if (std.meta.eql(filter, self.filter)) return false;
        self.filter = filter;
        self.nodes.clearRetainingCapacity();
        self.names.clearRetainingCapacity();
        self.zoom_len = 0;
        return true;
    }

    /// The depth `node` is drawn at under the root span, or null when it
    /// is not under it.
    pub fn row(self: *const Model, node: u32) ?u32 {
        const top = self.root();
        var at = node;
        while (at != top) : (at = self.nodes.items[at].parent) {
            if (at == none or at == 0) return null;
        }
        return self.nodes.items[node].depth - self.nodes.items[top].depth;
    }

    /// `node`'s span in a pane `width` pixels wide, or null when it is not
    /// under the root span. Edges are cumulative, so siblings tile their
    /// parent's span exactly with no gaps or overlaps.
    pub fn span(self: *const Model, node: u32, width: i32) ?Span {
        _ = self.row(node) orelse return null;
        if (node == self.root()) return .{ .x = 0, .w = width };
        const parent = self.nodes.items[node].parent;
        const outer = self.span(parent, width).?;
        const whole = self.nodes.items[parent].total;
        if (whole == 0) return .{ .x = outer.x, .w = 0 };
        var before: u64 = 0;
        var at = self.nodes.items[parent].first_child;
        while (at != node) : (at = self.nodes.items[at].next_sibling) before += self.nodes.items[at].total;
        const start = edge(outer, before, whole);
        return .{ .x = start, .w = edge(outer, before + self.nodes.items[node].total, whole) - start };
    }

    /// The node at pixel `x` on drawn row `depth` in a pane `width` pixels
    /// wide, or null for an empty spot. A box holds its left edge and not
    /// its right one; a box with no width holds nothing.
    pub fn hit(self: *const Model, x: i32, depth: u32, width: i32) ?u32 {
        if (self.nodes.items.len == 0 or x < 0 or x >= width) return null;
        var at = self.root();
        var outer: Span = .{ .x = 0, .w = width };
        var down: u32 = 0;
        while (down < depth) : (down += 1) {
            const whole = self.nodes.items[at].total;
            var before: u64 = 0;
            var kid = self.nodes.items[at].first_child;
            const found: ?u32 = while (kid != none) : (kid = self.nodes.items[kid].next_sibling) {
                const start = edge(outer, before, whole);
                before += self.nodes.items[kid].total;
                const end = edge(outer, before, whole);
                if (x >= start and x < end) {
                    outer = .{ .x = start, .w = end - start };
                    break kid;
                }
            } else null;
            at = found orelse return null;
        }
        return at;
    }
};

fn edge(outer: Span, part: u64, whole: u64) i32 {
    const wide: u64 = @intCast(@max(outer.w, 0));
    return outer.x + @as(i32, @intCast(wide * part / whole));
}
