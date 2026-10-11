//! Tests for src/interfaces/gui/flame_model.zig (RA8EMU-835) on hand-written
//! folded rows: merge, totals and self, name-ordered widths, zoom and back,
//! the core and thread filter, and the hit test at box edges.
const std = @import("std");
const gui_app = @import("gui_app");
const flame = gui_app.flame_model;

const rows =
    \\main;a;x 3
    \\main;b 2
    \\main;a 1
    \\main;a;y 4
    \\
;

/// The node at the end of `path` (frames joined by ';').
fn find(model: *const flame.Model, path: []const u8) !u32 {
    var at: u32 = 0;
    var frames = std.mem.splitScalar(u8, path, ';');
    walk: while (frames.next()) |frame| {
        var kid = model.get(at).first_child;
        while (kid != flame.none) : (kid = model.get(kid).next_sibling) {
            if (std.mem.eql(u8, model.name(kid), frame)) {
                at = kid;
                continue :walk;
            }
        }
        return error.NotFound;
    }
    return at;
}

fn loaded(text: []const u8) !flame.Model {
    var model = flame.Model.init(std.testing.allocator);
    errdefer model.deinit();
    try model.load(text);
    return model;
}

fn expectSpan(model: *const flame.Model, path: []const u8, x: i32, w: i32) !void {
    const got = model.span(try find(model, path), 100).?;
    try std.testing.expectEqual(flame.Span{ .x = x, .w = w }, got);
}

test "common prefixes merge, each node keeps its total and self" {
    var model = try loaded(rows);
    defer model.deinit();
    try std.testing.expectEqual(@as(u64, 10), model.window());
    const main = model.get(try find(&model, "main"));
    try std.testing.expectEqual(@as(u64, 10), main.total);
    try std.testing.expectEqual(@as(u64, 0), main.self);
    const a = model.get(try find(&model, "main;a"));
    try std.testing.expectEqual(@as(u64, 8), a.total);
    try std.testing.expectEqual(@as(u64, 1), a.self);
    try std.testing.expectEqual(@as(u64, 4), model.get(try find(&model, "main;a;y")).self);
    try std.testing.expectEqual(@as(usize, 6), model.nodes.items.len);
}

test "children are ordered by name and tile their parent by total" {
    var model = try loaded(rows);
    defer model.deinit();
    try std.testing.expectEqualStrings("a", model.name(model.get(try find(&model, "main")).first_child));
    try expectSpan(&model, "main", 0, 100);
    try expectSpan(&model, "main;a", 0, 80);
    try expectSpan(&model, "main;b", 80, 20);
    try expectSpan(&model, "main;a;x", 0, 30);
    try expectSpan(&model, "main;a;y", 30, 40);
}

test "the same rows in another order draw the same picture" {
    var model = try loaded(rows);
    defer model.deinit();
    var shuffled = try loaded("main;a;y 4\nmain;a 1\nmain;b 2\nmain;a;x 3\n");
    defer shuffled.deinit();
    for ([_][]const u8{ "main;a", "main;b", "main;a;x", "main;a;y" }) |path| {
        try std.testing.expectEqual(model.span(try find(&model, path), 100), shuffled.span(try find(&shuffled, path), 100));
    }
}

test "malformed lines are skipped" {
    var model = try loaded("nocount\nmain;c abc\n 5\nmain;d 2\n");
    defer model.deinit();
    try std.testing.expectEqual(@as(u64, 2), model.window());
    try std.testing.expectError(error.NotFound, find(&model, "main;c"));
}

test "zoom makes a node the root span and back undoes it" {
    var model = try loaded(rows);
    defer model.deinit();
    const a = try find(&model, "main;a");
    model.zoom(a);
    try std.testing.expectEqual(a, model.root());
    try std.testing.expectEqual(@as(u64, 8), model.window());
    try expectSpan(&model, "main;a", 0, 100);
    try expectSpan(&model, "main;a;x", 0, 37);
    try expectSpan(&model, "main;a;y", 37, 50);
    try std.testing.expect(model.span(try find(&model, "main;b"), 100) == null);
    try std.testing.expectEqual(@as(?u32, 1), model.row(try find(&model, "main;a;x")));
    try std.testing.expect(model.hit(0, 0, 100).? == a);
    try std.testing.expect(model.back());
    try std.testing.expectEqual(@as(u32, 0), model.root());
    try std.testing.expect(!model.back());
}

test "the hit test holds a box's left edge and not its right one" {
    var model = try loaded(rows);
    defer model.deinit();
    try std.testing.expectEqual(@as(?u32, 0), model.hit(0, 0, 100));
    try std.testing.expectEqual(try find(&model, "main"), model.hit(99, 1, 100).?);
    try std.testing.expectEqual(try find(&model, "main;a"), model.hit(79, 2, 100).?);
    try std.testing.expectEqual(try find(&model, "main;b"), model.hit(80, 2, 100).?);
    try std.testing.expectEqual(try find(&model, "main;a;x"), model.hit(29, 3, 100).?);
    try std.testing.expectEqual(try find(&model, "main;a;y"), model.hit(30, 3, 100).?);
    try std.testing.expect(model.hit(70, 3, 100) == null);
    try std.testing.expect(model.hit(100, 1, 100) == null);
    try std.testing.expect(model.hit(-1, 1, 100) == null);
    try std.testing.expect(model.hit(0, 4, 100) == null);
}

test "choosing another core or thread empties the tree until the next load" {
    var model = try loaded(rows);
    defer model.deinit();
    model.zoom(try find(&model, "main;a"));
    try std.testing.expect(!model.choose(.{}));
    try std.testing.expect(model.choose(.{ .core = .cpu1, .thread = 0x2202_5060 }));
    try std.testing.expectEqual(@as(u64, 0), model.window());
    try std.testing.expect(model.hit(0, 0, 100) == null);
    const asked = model.filter.ask();
    try std.testing.expectEqual(.cpu1, asked.core);
    try std.testing.expectEqual(@as(u32, 0x2202_5060), asked.thread);
}
