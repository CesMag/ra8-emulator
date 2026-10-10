//! Host tests for the shell frame (RA8EMU-764): the panes sit above the
//! status strip, each leaf gets a title bar over a body, the painter fills
//! every body once, and the chrome lands in the right colours.
const std = @import("std");
const ra8 = @import("ra8");
const gui_app = @import("gui_app");
const status_capture = gui_app.status_capture;
const draw_list = ra8.render.draw_list;
const raster = ra8.render.raster;
const font = ra8.render.font;
const pane_layout = gui_app.pane_layout;
const status_bar = gui_app.status_bar;
const strip = gui_app.status_strip;
const time_bar = gui_app.time_bar;
const frame = gui_app.shell_frame;
const State = gui_app.session_link.State;

const width: i32 = 480;
const height: i32 = 320;
const up: State = .{ .connected = .{ .version = 1, .caps = 0 } };

const Count = struct {
    calls: usize = 0,
    bodies: [8]draw_list.Rect = undefined,

    fn paint(context: *anyopaque, list: *draw_list.DrawList, pane: pane_layout.Pane, body: draw_list.Rect) anyerror!void {
        _ = list;
        _ = pane;
        const self: *Count = @ptrCast(@alignCast(context));
        self.bodies[self.calls] = body;
        self.calls += 1;
    }
};

const Scene = struct {
    layout: pane_layout.Layout,
    solved: pane_layout.Solved,
    list: draw_list.DrawList,
    pixels: raster.Framebuffer,

    fn init() !Scene {
        const gpa = std.testing.allocator;
        var layout = try pane_layout.twoCore(gpa);
        errdefer layout.deinit();
        const solved = try frame.solve(&layout, gpa, width, height);
        return .{ .layout = layout, .solved = solved, .list = draw_list.DrawList.init(gpa, width, height), .pixels = try raster.Framebuffer.init(gpa, width, height) };
    }

    fn deinit(self: *Scene) void {
        const gpa = std.testing.allocator;
        self.solved.deinit(gpa);
        self.layout.deinit();
        self.list.deinit();
        self.pixels.deinit(gpa);
    }

    fn render(self: *Scene, status: *const status_bar.Status, painter: ?frame.Painter) !void {
        try frame.draw(&self.list, .{ .layout = &self.layout, .solved = &self.solved, .strip = status_capture.strip(status, up), .width = width, .height = height, .painter = painter });
        raster.draw(&self.pixels, &self.list, font.atlas);
    }

    fn at(self: *const Scene, x: i32, y: i32) draw_list.Color {
        return self.pixels.at(@intCast(x), @intCast(y));
    }
};

test "panes and pane titles name each kind and core" {
    try std.testing.expectEqualStrings("Console", frame.kindName(.console));
    try std.testing.expectEqualStrings("CPU1", frame.coreName(.cpu1));
}

test "the panes take the window above the time bar and the status strip" {
    const area = frame.panesArea(width, height);
    try std.testing.expectEqual(draw_list.Rect{ .x = 0, .y = 0, .w = width, .h = height - strip.height - time_bar.height }, area);
    try std.testing.expectEqual(@as(i32, 0), frame.panesArea(width, 4).h);
}

test "the time bar's row sits on top of the status strip, under the panes" {
    const row = frame.barArea(width, height);
    try std.testing.expectEqual(frame.panesArea(width, height).h, row.y);
    try std.testing.expectEqual(strip.area(width, height).y, row.y + row.h);
    try std.testing.expectEqual(@as(i32, width), row.w);
}

test "a leaf splits into a title bar over its body" {
    const leaf: draw_list.Rect = .{ .x = 10, .y = 20, .w = 100, .h = 60 };
    const title = frame.titleOf(leaf);
    const body = frame.bodyOf(leaf);
    try std.testing.expectEqual(frame.title_h, title.h);
    try std.testing.expectEqual(leaf.y + frame.title_h, body.y);
    try std.testing.expectEqual(leaf.h, title.h + body.h);
    try std.testing.expectEqual(@as(i32, 0), frame.bodyOf(.{ .x = 0, .y = 0, .w = 9, .h = 5 }).h);
}

test "the painter fills each leaf's body exactly once" {
    var scene = try Scene.init();
    defer scene.deinit();
    var count: Count = .{};
    const status: status_bar.Status = .{};
    try scene.render(&status, .{ .context = &count, .paint = Count.paint });
    try std.testing.expectEqual(scene.solved.panes.items.len, count.calls);
    for (scene.solved.panes.items, 0..) |placed, i| {
        try std.testing.expectEqual(frame.bodyOf(placed.area), count.bodies[i]);
    }
}

test "the chrome paints titles, gutters, bodies and the strip" {
    var scene = try Scene.init();
    defer scene.deinit();
    const status: status_bar.Status = .{};
    try scene.render(&status, null);
    const first = scene.solved.panes.items[0].area;
    try std.testing.expectEqual(frame.title_fill, scene.at(first.x + first.w - 1, first.y));
    try std.testing.expectEqual(frame.background, scene.at(first.x + 1, first.y + first.h - 1));
    const gap = scene.solved.gutters.items[0].area;
    try std.testing.expectEqual(frame.gutter_fill, scene.at(gap.x, gap.y + 1));
    try std.testing.expectEqual(strip.border, scene.at(width - 1, height - strip.height));
}
