//! Host tests for the time bar (RA8EMU-807): where each control sits, what a
//! click lands on, a pinned CPU-backend golden frame, a narrow bar that never
//! paints past its area, and clicks on step, run and pause: a step goes to
//! a spawned `serve --stdio` child, and run and pause light and unlight the
//! shell's sliced run (shell_run_test.zig runs the slices).
const std = @import("std");
const dark = &@import("gui_app").colors.palettes.dark;
const light = &@import("gui_app").colors.palettes.light;
const Theme = @import("gui_app").colors.Theme;
const ra8 = @import("ra8");
const gui_app = @import("gui_app");
const test_paths = @import("test_paths");
const draw_list = ra8.render.draw_list;
const raster = ra8.render.raster;
const font = ra8.render.font;
const status_bar = gui_app.status.bar;
const speed_field = gui_app.speed_field;
const time_readout = gui_app.time.readout;
const session_link = gui_app.session_link;
const bar = gui_app.time_bar;
const capture = gui_app.time.bar_capture;
const Run = gui_app.shell.run.Run;
const proto = ra8.rpc.session.rpc;
const Link = session_link.Link;
const Status = status_bar.Status;
const Rect = draw_list.Rect;

const Env = proto.Client.Env;
const elf_path = "tests/fixtures/fpu/fp_basic.elf";

const Models = struct {
    status: Status = .{},
    field: speed_field.Field = .{},
    readout: time_readout.Readout = .{},
    texts: capture.Texts = .{},

    fn sample() Models {
        var models: Models = .{};
        models.status.run = .{ .halted = .{ .address = 0x0800_0100, .reason = .stepped } };
        models.field.applied = 250;
        models.readout.virtual_ns = 83_456_000_000;
        models.readout.achieved_milli = 120;
        return models;
    }

    fn view(self: *Models, editing: bool) bar.View {
        return capture.view(&self.texts, &self.status, &self.field, &self.readout, editing);
    }
};

const Scene = struct {
    list: draw_list.DrawList,
    frame: raster.Framebuffer,
    /// The palette the scene paints with (RA8EMU-961).
    theme: *const Theme = dark,

    fn init(width: u32, height: u32) !Scene {
        return .{ .list = draw_list.DrawList.init(std.testing.allocator, width, height), .frame = try raster.Framebuffer.init(std.testing.allocator, width, height) };
    }

    fn deinit(self: *Scene) void {
        self.list.deinit();
        self.frame.deinit(std.testing.allocator);
    }

    fn render(self: *Scene, area: Rect, view: bar.View) !void {
        try bar.draw(&self.list, self.theme, area, view);
        raster.draw(&self.frame, &self.list, font.atlas);
    }

    // TEMPORARY golden dump, never committed.

    fn digest(self: *const Scene) u64 {
        const hash = std.hash.Fnv1a_64.hash(std.mem.sliceAsBytes(self.frame.pixels));
        return hash;
    }
};

fn middle(area: Rect) [2]i32 {
    return .{ area.x + @divTrunc(area.w, 2), area.y + @divTrunc(area.h, 2) };
}

test "the controls sit left to right and the clock takes what is left" {
    const area: Rect = .{ .x = 0, .y = 0, .w = 480, .h = bar.height };
    const layout = bar.Layout.of(area);
    try std.testing.expectEqual(@as(i32, bar.pad), layout.run.x);
    try std.testing.expectEqual(layout.run.x + layout.run.w + bar.gap, layout.pause.x);
    try std.testing.expectEqual(layout.pause.x + layout.pause.w + bar.gap, layout.step.x);
    try std.testing.expectEqual(layout.step.x + layout.step.w + bar.gap, layout.field.x);
    try std.testing.expectEqual(@as(i32, @intCast(font.textWidth(bar.field_chars))) + 2 * bar.pad, layout.field.w);
    try std.testing.expectEqual(area.w - bar.pad, layout.clock.x + layout.clock.w);
    try std.testing.expectEqual(@as(i32, bar.control_h), layout.run.h);
}

test "a click lands on the control under it, and nothing in the gaps or the clock" {
    const area: Rect = .{ .x = 20, .y = 100, .w = 480, .h = bar.height };
    const layout = bar.Layout.of(area);
    for ([_]bar.Control{ .run, .pause, .step, .field }) |control| {
        const at = middle(layout.rect(control));
        try std.testing.expectEqual(@as(?bar.Control, control), bar.hit(area, at[0], at[1]));
    }
    try std.testing.expectEqual(@as(?bar.Control, null), bar.hit(area, layout.run.x + layout.run.w, layout.run.y + 2));
    const clock = middle(layout.clock);
    try std.testing.expectEqual(@as(?bar.Control, null), bar.hit(area, clock[0], clock[1]));
    try std.testing.expectEqual(@as(?bar.Control, null), bar.hit(area, layout.run.x + 1, area.y));
}

test "the bar rasterises to the pinned golden frame" {
    var scene = try Scene.init(480, bar.height);
    defer scene.deinit();
    var models = Models.sample();
    try scene.render(.{ .x = 0, .y = 0, .w = 480, .h = bar.height }, models.view(false));
    try std.testing.expectEqual(@as(u64, 15007699599523115719), scene.digest());
}

test "the bar rasterises to the pinned golden frame in the light theme" {
    var scene = try Scene.init(480, bar.height);
    defer scene.deinit();
    scene.theme = light;
    var models = Models.sample();
    try scene.render(.{ .x = 0, .y = 0, .w = 480, .h = bar.height }, models.view(false));
    try std.testing.expectEqual(@as(u64, 16234191626027740266), scene.digest());
}

test "the editing field rasterises to its pinned golden frame" {
    var scene = try Scene.init(480, bar.height);
    defer scene.deinit();
    var models = Models.sample();
    models.status.run = .running;
    models.field.typed("5");
    try scene.render(.{ .x = 0, .y = 0, .w = 480, .h = bar.height }, models.view(true));
    try std.testing.expectEqual(@as(u64, 17622458108587683926), scene.digest());
}

test "the bar with an RTC date rasterises to its pinned golden frame, wide enough for the whole line" {
    var scene = try Scene.init(640, bar.height);
    defer scene.deinit();
    var models = Models.sample();
    models.readout.date = .{ .year = 2026, .month = 10, .day = 8, .hour = 9, .minute = 47, .second = 5 };
    try scene.render(.{ .x = 0, .y = 0, .w = 640, .h = bar.height }, models.view(false));
    try std.testing.expectEqual(@as(u64, 9817191518527044167), scene.digest());
}

test "a bar too narrow for its controls paints nothing past its area" {
    var scene = try Scene.init(200, 40);
    defer scene.deinit();
    var models = Models.sample();
    const area: Rect = .{ .x = 30, .y = 10, .w = 70, .h = bar.height };
    try scene.render(area, models.view(true));
    const clear: draw_list.Color = .{ .r = 0, .g = 0, .b = 0, .a = 0 };
    var painted: usize = 0;
    var y: u32 = 0;
    while (y < scene.frame.height) : (y += 1) {
        var x: u32 = 0;
        while (x < scene.frame.width) : (x += 1) {
            if (area.contains(@intCast(x), @intCast(y))) {
                painted += 1;
            } else try std.testing.expectEqual(clear, scene.frame.at(x, y));
        }
    }
    try std.testing.expect(painted > 0);
    try std.testing.expect(bar.Layout.of(area).field.empty());
}

test "an empty bar draws nothing" {
    var list = draw_list.DrawList.init(std.testing.allocator, 8, 8);
    defer list.deinit();
    var models = Models.sample();
    try bar.draw(&list, dark, .{ .x = 0, .y = 0, .w = 0, .h = bar.height }, models.view(false));
    try std.testing.expectEqual(@as(usize, 0), list.commands.items.len);
}

fn pending(status: *const Status) bool {
    return status.load_id != null or status.pc_id != null or status.run == .running;
}

/// Pump the link into the status until nothing is outstanding, for ten seconds.
fn settle(link: *Link, status: *Status) !void {
    const deadline = std.Io.Timestamp.now(std.testing.io, .awake).toMilliseconds() + 10_000;
    while (pending(status)) {
        if (std.Io.Timestamp.now(std.testing.io, .awake).toMilliseconds() > deadline) return error.Timeout;
        if (link.state != .connected) return error.LinkLost;
        if (link.pump()) |arrival| status.observe(link, arrival) else try std.testing.io.sleep(.fromMilliseconds(1), .awake);
    }
}

fn connect(link: *Link) !void {
    const deadline = std.Io.Timestamp.now(std.testing.io, .awake).toMilliseconds() + 10_000;
    while (link.state == .connecting and std.Io.Timestamp.now(std.testing.io, .awake).toMilliseconds() < deadline) {
        _ = link.pump();
        try std.testing.io.sleep(.fromMilliseconds(1), .awake);
    }
    try std.testing.expect(link.state == .connected);
}

/// Click the middle of `control` in `area` and press what the hit test found.
fn click(area: Rect, control: bar.Control, status: *Status, run: *Run, link: *Link) !void {
    const at = middle(bar.Layout.of(area).rect(control));
    const found = bar.hit(area, at[0], at[1]) orelse return error.Missed;
    try std.testing.expectEqual(control, found);
    try capture.press(found, status, run, link);
}

test "a click on step drives a served session, and run and pause light and unlight the sliced run" {
    const gpa = std.testing.allocator;
    var local: session_link.Local = undefined;
    try local.spawn(std.testing.io, test_paths.emulator, elf_path);
    errdefer local.child.kill(std.testing.io);
    const rx = try gpa.alloc(u8, 2 * Env.max_frame);
    defer gpa.free(rx);
    const tx = try gpa.alloc(u8, Env.max_frame);
    defer gpa.free(tx);
    var link: Link = undefined;
    link.open(local.transport(), rx, tx);
    try connect(&link);

    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, elf_path, gpa, .limited(1 << 20));
    defer gpa.free(bytes);
    var status: Status = .{};
    try status.load(&link, elf_path, bytes);
    try settle(&link, &status);
    const reset_pc = status.run.halted.address;
    const area: Rect = .{ .x = 0, .y = 0, .w = 480, .h = bar.height };

    var run: Run = .{};

    try click(area, .step, &status, &run, &link);
    try settle(&link, &status);
    try std.testing.expectEqual(@as(?proto.StopReason, .stepped), status.run.halted.reason);
    const stepped_to = status.run.halted.address;
    try std.testing.expect(stepped_to != reset_pc);

    // Run sends nothing: it lights the run, and the shell's frames pay it.
    try click(area, .run, &status, &run, &link);
    try std.testing.expectEqual(status_bar.Run.running, status.run);
    try std.testing.expect(run.lit);
    try std.testing.expectEqual(@as(?u32, null), status.run_id);
    try std.testing.expectEqual(stepped_to, run.address);

    // A step while it runs is not sent either.
    try click(area, .step, &status, &run, &link);
    try std.testing.expectEqual(@as(?u32, null), status.run_id);

    try click(area, .pause, &status, &run, &link);
    try std.testing.expect(!run.lit);
    status.haltedAt(run.halted() orelse return error.NoHalt);
    try std.testing.expectEqual(stepped_to, status.run.halted.address);

    try click(area, .field, &status, &run, &link);
    try std.testing.expect(!pending(&status));

    local.end();
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, try local.reap());
}
