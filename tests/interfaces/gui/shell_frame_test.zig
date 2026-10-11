//! Host tests for the shell frame (RA8EMU-764): the panes sit above the
//! status strip, each leaf gets a title bar over a body, the painter fills
//! every body once, and the chrome lands in the right colours.
const std = @import("std");
const dark = &@import("gui_app").colors.palettes.dark;
const ra8 = @import("ra8");
const gui_app = @import("gui_app");
const status_capture = gui_app.status.capture;
const draw_list = ra8.render.draw_list;
const raster = ra8.render.raster;
const font = ra8.render.font;
const pane_layout = gui_app.pane_layout;
const status_bar = gui_app.status.bar;
const strip = gui_app.status_strip;
const time_bar = gui_app.time_bar;
const frame = gui_app.shell.frame;
const State = gui_app.session_link.State;

const width: i32 = 480;
const height: i32 = 320;
const up: State = .{ .connected = .{ .version = 1, .caps = 0 } };

const Count = struct {
    calls: usize = 0,
    bodies: [8]draw_list.Rect = undefined,

    fn paint(context: *anyopaque, list: *draw_list.DrawList, _: *const gui_app.colors.Theme, pane: pane_layout.Pane, body: draw_list.Rect) anyerror!void {
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
        try frame.draw(&self.list, dark, .{ .layout = &self.layout, .solved = &self.solved, .strip = status_capture.strip(status, up), .width = width, .height = height, .painter = painter });
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
    try std.testing.expectEqual(dark.border, scene.at(first.x + first.w - 1, first.y));
    try std.testing.expectEqual(dark.face, scene.at(first.x + first.w - 2, first.y + 1));
    try std.testing.expectEqual(dark.border, scene.at(first.x + 1, first.y + first.h - 1));
    try std.testing.expectEqual(dark.background, scene.at(first.x + 1, first.y + first.h - 2));
    const gap = scene.solved.gutters.items[0].area;
    try std.testing.expectEqual(dark.gutter, scene.at(gap.x, gap.y + 1));
    try std.testing.expectEqual(dark.border, scene.at(width - 1, height - strip.height));
}

test "the perimeter border is retained when a painter fills the body" {
    var scene = try Scene.init();
    defer scene.deinit();
    const status: status_bar.Status = .{};
    const Filler = struct {
        fn paint(_: *anyopaque, list: *draw_list.DrawList, _: *const gui_app.colors.Theme, _: pane_layout.Pane, body: draw_list.Rect) anyerror!void {
            try list.fill(body, dark.face);
        }
    };
    try scene.render(&status, .{ .context = undefined, .paint = Filler.paint });
    const first = scene.solved.panes.items[0].area;
    try std.testing.expectEqual(dark.border, scene.at(first.x + first.w - 1, first.y));
    try std.testing.expectEqual(dark.border, scene.at(first.x + 1, first.y + first.h - 1));
    try std.testing.expectEqual(dark.border, scene.at(first.x, first.y + first.h - 2));
    try std.testing.expectEqual(dark.border, scene.at(first.x + first.w - 1, first.y + first.h - 2));
    try std.testing.expectEqual(dark.face, scene.at(first.x + 1, first.y + first.h - 2));
}

test "shell frame edge: panesArea and barArea under constrained heights" {
    const strip_h = strip.height;
    const time_h = time_bar.height;
    const chrome_h = strip_h + time_h;

    const zero_panes = frame.panesArea(480, 10);
    try std.testing.expectEqual(@as(i32, 0), zero_panes.h);
    try std.testing.expect(zero_panes.w == 480);

    const exact_panes = frame.panesArea(480, chrome_h);
    try std.testing.expectEqual(@as(i32, 0), exact_panes.h);

    const one_px_panes = frame.panesArea(480, chrome_h + 1);
    try std.testing.expectEqual(@as(i32, 1), one_px_panes.h);

    const bar = frame.barArea(480, 100);
    try std.testing.expectEqual(time_h, bar.h);
    try std.testing.expectEqual(100 - chrome_h, bar.y);
}

test "shell frame edge: titleOf and bodyOf never invert or exceed area" {
    const areas = [_]draw_list.Rect{
        .{ .x = 0, .y = 0, .w = 0, .h = 0 },
        .{ .x = 5, .y = 5, .w = 1, .h = 1 },
        .{ .x = 10, .y = 10, .w = 10, .h = frame.title_h - 1 },
        .{ .x = 10, .y = 10, .w = 10, .h = frame.title_h },
        .{ .x = 10, .y = 10, .w = 10, .h = frame.title_h + 1 },
        .{ .x = 10, .y = 10, .w = 200, .h = 500 },
        .{ .x = -50, .y = -50, .w = 20, .h = 30 },
    };

    for (areas) |area| {
        const title = frame.titleOf(area);
        const body = frame.bodyOf(area);

        try std.testing.expect(title.w == area.w);
        try std.testing.expect(title.h <= frame.title_h);
        try std.testing.expect(title.h <= area.h);
        try std.testing.expect(title.x == area.x);
        try std.testing.expect(title.y == area.y);

        try std.testing.expect(body.w == area.w);
        try std.testing.expect(body.h >= 0);
        try std.testing.expect(body.x == area.x);
        try std.testing.expect(body.y == area.y + title.h);
        try std.testing.expectEqual(area.h, title.h + body.h);
    }
}

test "shell frame edge: draw renders across extreme window dimensions without panic" {
    const gpa = std.testing.allocator;
    const test_sizes = [_][2]i32{
        .{ 480, 320 },
        .{ 800, 600 },
        .{ 1280, 860 },
        .{ 481, 321 },
        .{ 200, 100 },
        .{ 120, 60 },
        .{ 2000, 1200 },
    };

    for (test_sizes) |dim| {
        const w = dim[0];
        const h = dim[1];

        var layout = try pane_layout.twoCore(gpa);
        defer layout.deinit();

        var solved = try frame.solve(&layout, gpa, w, h);
        defer solved.deinit(gpa);

        var list = draw_list.DrawList.init(gpa, @intCast(w), @intCast(h));
        defer list.deinit();

        var count: Count = .{};
        const status: status_bar.Status = .{};

        try frame.draw(&list, dark, .{
            .layout = &layout,
            .solved = &solved,
            .strip = status_capture.strip(&status, up),
            .width = w,
            .height = h,
            .painter = .{ .context = &count, .paint = Count.paint },
        });

        for (list.commands.items) |cmd| {
            switch (cmd.shape) {
                .fill => |shape| {
                    try std.testing.expect(shape.area.w >= 0);
                    try std.testing.expect(shape.area.h >= 0);
                },
                .line => {},
                .glyph => {},
                .image => {},
            }
        }

        var pixels = try raster.Framebuffer.init(gpa, @intCast(w), @intCast(h));
        defer pixels.deinit(gpa);
        raster.draw(&pixels, &list, font.atlas);
    }
}

test "shell frame edge: leaf title clipping and border drawing with narrow widths" {
    const gpa = std.testing.allocator;
    const narrow_widths = [_]i32{ 1, 2, 3, 4, 7, 8, 9, 10, 15, 20, 50 };

    for (narrow_widths) |nw| {
        var layout = try pane_layout.twoCore(gpa);
        defer layout.deinit();

        const h = 200;
        var solved = try frame.solve(&layout, gpa, nw, h);
        defer solved.deinit(gpa);

        var list = draw_list.DrawList.init(gpa, @intCast(nw), @intCast(h));
        defer list.deinit();

        const status: status_bar.Status = .{};

        try frame.draw(&list, dark, .{
            .layout = &layout,
            .solved = &solved,
            .strip = status_capture.strip(&status, up),
            .width = nw,
            .height = h,
            .painter = null,
        });

        try std.testing.expectEqual(@as(usize, 0), list.clips.items.len);

        var pixels = try raster.Framebuffer.init(gpa, @intCast(nw), @intCast(h));
        defer pixels.deinit(gpa);
        raster.draw(&pixels, &list, font.atlas);
    }
}
