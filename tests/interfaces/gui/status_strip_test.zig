//! Host tests for the status strip (RA8EMU-759) and gui/status_capture.zig
//! (RA8EMU-1085): the tone each state takes,
//! where the strip sits, a pinned CPU-backend golden frame, and a narrow
//! window that cuts the text to whole cells inside the strip.
const std = @import("std");
const ra8 = @import("ra8");
const gui_app = @import("gui_app");
const draw_list = ra8.render.draw_list;
const raster = ra8.render.raster;
const font = ra8.render.font;
const status_bar = gui_app.status_bar;
const strip = gui_app.status_strip;
const capture = gui_app.status_capture;
const State = gui_app.session_link.State;

const up: State = .{ .connected = .{ .version = 1, .caps = 0 } };

fn sample() status_bar.Status {
    var status: status_bar.Status = .{};
    status.image = status_bar.Image.of("app.elf", "abc");
    status.run = .{ .halted = .{ .address = 0x0800_0100, .reason = .stepped } };
    return status;
}

const Scene = struct {
    list: draw_list.DrawList,
    frame: raster.Framebuffer,
    width: u32,

    fn init(width: u32) !Scene {
        const h: u32 = @intCast(strip.height);
        return .{ .list = draw_list.DrawList.init(std.testing.allocator, width, h), .frame = try raster.Framebuffer.init(std.testing.allocator, width, h), .width = width };
    }

    fn deinit(self: *Scene) void {
        self.list.deinit();
        self.frame.deinit(std.testing.allocator);
    }

    fn render(self: *Scene, status: *const status_bar.Status, state: State) !void {
        const view = capture.strip(status, state);
        try strip.draw(&self.list, strip.area(@intCast(self.width), strip.height), &view);
        raster.draw(&self.frame, &self.list, font.atlas);
    }

    fn digest(self: *const Scene) u64 {
        return std.hash.Fnv1a_64.hash(std.mem.sliceAsBytes(self.frame.pixels));
    }
};

test "the worst news sets the tone: failure, refusal, then the run state" {
    var status = sample();
    try std.testing.expectEqual(strip.Tone.bad, capture.tone(&status, .{ .failed = .ended }));
    try std.testing.expectEqual(strip.Tone.waiting, capture.tone(&status, .connecting));
    try std.testing.expectEqual(strip.Tone.halted, capture.tone(&status, up));
    status.run = .running;
    try std.testing.expectEqual(strip.Tone.running, capture.tone(&status, up));
    status.refused = .run;
    try std.testing.expectEqual(strip.Tone.bad, capture.tone(&status, up));
    try std.testing.expectEqual(strip.Tone.good, capture.tone(&status_bar.Status{}, up));
}

test "the strip runs along the bottom of the window" {
    const at = strip.area(640, 480);
    try std.testing.expectEqual(draw_list.Rect{ .x = 0, .y = 480 - strip.height, .w = 640, .h = strip.height }, at);
}

test "the strip rasterises to the pinned golden frame" {
    var scene = try Scene.init(480);
    defer scene.deinit();
    const status = sample();
    try scene.render(&status, up);
    try std.testing.expectEqual(@as(u64, 9739888199703139288), scene.digest());
}

test "a narrow window cuts the line to whole cells inside the strip" {
    var scene = try Scene.init(120);
    defer scene.deinit();
    const status = sample();
    try scene.render(&status, up);
    try std.testing.expectEqual(@as(u64, 14404408989058805433), scene.digest());
    var y: u32 = 1;
    while (y < scene.frame.height) : (y += 1) {
        var x: u32 = scene.width - @as(u32, @intCast(strip.pad));
        while (x < scene.width) : (x += 1) try std.testing.expectEqual(strip.background, scene.frame.at(x, y));
    }
}

test "an empty strip draws nothing" {
    var list = draw_list.DrawList.init(std.testing.allocator, 8, 8);
    defer list.deinit();
    const status = sample();
    const view = capture.strip(&status, up);
    try strip.draw(&list, .{ .x = 0, .y = 0, .w = 0, .h = strip.height }, &view);
    try std.testing.expectEqual(@as(usize, 0), list.commands.items.len);
}
