//! Covers src/interfaces/gui/ui/flame_pane.zig (RA8EMU-835) on hand-written
//! folded rows: a box sits on its depth's row over its model span, a click
//! maps back to the node under it, the root box reads "all", a name keeps
//! its hue, a pane too narrow draws nothing, and a hovered frame
//! rasterises to a pinned golden frame in each palette.
const std = @import("std");
const dark = &@import("gui_app").colors.palettes.dark;
const light = &@import("gui_app").colors.palettes.light;
const Theme = @import("gui_app").colors.Theme;
const ra8 = @import("ra8");
const gui_app = @import("gui_app");

const draw_list = ra8.render.draw_list;
const raster = ra8.render.raster;
const font = ra8.render.font;
const flame = gui_app.flame.model;
const pane = gui_app.flame_pane;
const Rect = draw_list.Rect;

const rows =
    \\main;a;x 3
    \\main;b 2
    \\main;a 1
    \\main;a;y 4
    \\
;

const area: Rect = .{ .x = 0, .y = 0, .w = 320, .h = 2 * pane.pad + 5 * pane.row_h };

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

fn loaded() !flame.Model {
    var model = flame.Model.init(std.testing.allocator);
    errdefer model.deinit();
    try model.load(rows);
    return model;
}

// TEMPORARY golden dump, never committed.

fn digest(theme: *const Theme, model: *const flame.Model, hover: ?u32) !u64 {
    var list = draw_list.DrawList.init(std.testing.allocator, @intCast(area.w), @intCast(area.h));
    defer list.deinit();
    var frame = try raster.Framebuffer.init(std.testing.allocator, @intCast(area.w), @intCast(area.h));
    defer frame.deinit(std.testing.allocator);
    try pane.draw(&list, theme, area, model, hover);
    raster.draw(&frame, &list, font.atlas);
    const hash = std.hash.Fnv1a_64.hash(std.mem.sliceAsBytes(frame.pixels));
    return hash;
}

test "four depths fit above the tip line" {
    try std.testing.expectEqual(@as(usize, 4), pane.rows(area));
    const tip = pane.tipRect(area);
    try std.testing.expectEqual(area.h - pane.pad, tip.y + tip.h);
}

test "a click in a box lands on its node, and nothing past the deepest box" {
    var model = try loaded();
    defer model.deinit();
    for ([_][]const u8{ "main", "main;a", "main;b", "main;a;x", "main;a;y" }) |path| {
        const node = try find(&model, path);
        const span = model.span(node, pane.width(area)).?;
        const box = pane.boxRect(area, model.row(node).?, span);
        const x = box.x + @divTrunc(box.w, 2);
        try std.testing.expectEqual(@as(?u32, node), pane.nodeAt(area, &model, x, box.y + 1));
    }
    const b = pane.boxRect(area, 3, model.span(try find(&model, "main;b"), pane.width(area)).?);
    try std.testing.expectEqual(@as(?u32, null), pane.nodeAt(area, &model, b.x + 1, b.y + 1));
    try std.testing.expectEqual(@as(?u32, null), pane.nodeAt(area, &model, 10, pane.tipRect(area).y + 1));
}

test "the root box reads all, and a name keeps its hue" {
    var model = try loaded();
    defer model.deinit();
    try std.testing.expectEqualStrings(pane.root_label, pane.label(&model, 0));
    try std.testing.expectEqualStrings("main", pane.label(&model, try find(&model, "main")));
    try std.testing.expectEqual(pane.hue(dark, "main"), pane.hue(dark, "main"));
}

test "zoom puts the zoomed frame on the top row at full width" {
    var model = try loaded();
    defer model.deinit();
    const a = try find(&model, "main;a");
    model.zoom(a);
    try std.testing.expectEqual(@as(?u32, a), pane.nodeAt(area, &model, area.w - pane.pad - 1, pane.pad));
    try std.testing.expectEqual(@as(?u32, null), pane.nodeAt(area, &model, 10, pane.pad + 3 * pane.row_h));
}

test "a pane too narrow draws nothing" {
    var model = try loaded();
    defer model.deinit();
    var list = draw_list.DrawList.init(std.testing.allocator, 64, 64);
    defer list.deinit();
    try pane.draw(&list, dark, .{ .x = 0, .y = 0, .w = pane.min_w - 1, .h = area.h }, &model, null);
    try std.testing.expectEqual(@as(usize, 0), list.commands.items.len);
}

test "a hovered frame rasterises to the pinned golden frame" {
    var model = try loaded();
    defer model.deinit();
    try std.testing.expectEqual(@as(u64, 7355067893934834499), try digest(dark, &model, try find(&model, "main;a")));
}

test "a hovered frame rasterises to the pinned golden frame in the light theme" {
    var model = try loaded();
    defer model.deinit();
    try std.testing.expectEqual(@as(u64, 6511578080357726408), try digest(light, &model, try find(&model, "main;a")));
}
