//! The flame graph's done condition (RA8EMU-839, under RA8EMU-216): for one
//! virtual-time window on each core, the flame model built from the wire's
//! folded rows (RA8EMU-833) holds every row's frame path, each path's
//! self is the sum of the rows naming it, and the root's total is the sum of
//! the rows' counts. The session is the served call-tree pair with CPU1 up
//! (RA8EMU-1147), so both cores sample their own image.
const std = @import("std");
const ra8 = @import("ra8");
const gui_app = @import("gui_app");
const test_paths = @import("test_paths");

const setup = ra8.rpc.served_setup;
const folded = ra8.rpc.session_folded;
const proto = ra8.rpc.session_rpc;
const flame_model = gui_app.flame_model;

fn ask(context: anytype, wanted: proto.FoldedAsk) ![]const u8 {
    return switch (folded.folded(context, wanted)) {
        .ok => |rows| rows.text,
        .err => error.Refused,
    };
}

fn bothRan(opened: *setup.Served) !void {
    try opened.open(std.testing.allocator, std.testing.io, test_paths.call_tree);
    errdefer opened.deinit();
    opened.owner.session().live.budget = 200_000;
    try opened.openSecond(test_paths.call_tree_cpu1);
    try opened.sampleStacks(200);
    const session = opened.owner.session();
    _ = try session.run(.cpu1, .cont);
    _ = try session.run(.cpu0, .cont);
}

/// The node `path` (frames joined by ';') names under the tree's root.
fn pathNode(model: *const flame_model.Model, path: []const u8) ?u32 {
    var node: u32 = 0;
    var frames = std.mem.splitScalar(u8, path, ';');
    while (frames.next()) |frame| {
        var child = model.get(node).first_child;
        while (child != flame_model.none and !std.mem.eql(u8, model.name(child), frame)) child = model.get(child).next_sibling;
        if (child == flame_model.none) return null;
        node = child;
    }
    return node;
}

/// Load `rows` and check each row's frame path is in the tree, each path's
/// self is the sum of the rows naming it (the wire folds by address, so two
/// address stacks can share a name path; the model merges them the way
/// flamegraph.pl does), no other node holds samples of its own, and the
/// root totals the rows.
fn expectMatches(rows: []const u8) !u64 {
    var model = flame_model.Model.init(std.testing.allocator);
    defer model.deinit();
    try model.load(rows);
    const wanted = try std.testing.allocator.alloc(u64, model.nodes.items.len);
    defer std.testing.allocator.free(wanted);
    @memset(wanted, 0);
    var sum: u64 = 0;
    var lines = std.mem.tokenizeScalar(u8, rows, '\n');
    while (lines.next()) |line| {
        const cut = std.mem.lastIndexOfScalar(u8, line, ' ') orelse return error.Malformed;
        const count = try std.fmt.parseInt(u64, line[cut + 1 ..], 10);
        const node = pathNode(&model, line[0..cut]) orelse return error.PathMissing;
        wanted[node] += count;
        sum += count;
    }
    for (model.nodes.items, wanted) |node, self| try std.testing.expectEqual(self, node.self);
    try std.testing.expect(sum > 0);
    try std.testing.expectEqual(sum, model.window());
    return sum;
}

/// The first sample's time and one past the last one's on core `index`;
/// each core runs its own budget, so their samples cover different times.
fn coreSpan(store: anytype, index: u8) ?struct { first: u64, last: u64 } {
    var first: ?u64 = null;
    var last: u64 = 0;
    for (0..store.count) |at| {
        const sample = store.at(at);
        if (sample.core != index) continue;
        if (first == null) first = sample.at_ns;
        last = @max(last, sample.at_ns + 1);
    }
    return .{ .first = first orelse return null, .last = last };
}

test "each core's flame tree matches its folded rows over a window" {
    var opened: setup.Served = undefined;
    try bothRan(&opened);
    defer opened.deinit();
    const store = &opened.stacks.?.store;
    for ([_]proto.Core{ .cpu0, .cpu1 }) |core| {
        const span = coreSpan(store, @backingInt(core)) orelse return error.NothingSampled;
        const middle = span.first + (span.last - span.first) / 2;
        const whole = try expectMatches(try ask(&opened.context, .{ .core = core }));
        const early = try expectMatches(try ask(&opened.context, .{ .core = core, .from_ns = span.first, .to_ns = middle }));
        const late = try expectMatches(try ask(&opened.context, .{ .core = core, .from_ns = middle, .to_ns = span.last }));
        try std.testing.expectEqual(whole, early + late);
    }
}

test "the model's filter asks for the same rows the wire gives" {
    var opened: setup.Served = undefined;
    try bothRan(&opened);
    defer opened.deinit();
    var model = flame_model.Model.init(std.testing.allocator);
    defer model.deinit();
    _ = model.choose(.{ .core = .cpu1 });
    const rows = try ask(&opened.context, model.filter.ask());
    try model.load(rows);
    try std.testing.expect(pathNode(&model, "call_tree_cpu1.cpu1_outer") != null or std.mem.indexOf(u8, rows, "call_tree_cpu1.cpu1_outer") != null);
    try std.testing.expectEqual(try expectMatches(rows), model.window());
}
