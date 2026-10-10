//! Host tests for the shell's camera leaf (RA8EMU-796): the pick's spec text,
//! one ask per change while connected, the webcam's consent flag, the
//! session's answer moving the ring, clicks routed into the leaf's panel, and
//! the leaf painting the panel.
const std = @import("std");
const ra8 = @import("ra8");
const gui_app = @import("gui_app");
const status_capture = gui_app.status_capture;
const proto = ra8.rpc.session_rpc;
const Stdio = ra8.rpc.stdio_transport.Stdio;
const draw_list = ra8.render.draw_list;
const raster = ra8.render.raster;
const font = ra8.render.font;
const pane_layout = gui_app.pane_layout;
const frame = gui_app.shell_frame;
const panes = gui_app.shell_panes;
const status_bar = gui_app.status_bar;
const camera_view = gui_app.camera_view;
const session_link = gui_app.session_link;
const shell_camera = gui_app.shell_camera;
const Camera = shell_camera.Camera;
const Env = proto.Client.Env;

/// A link that has finished its greeting, writing into a pipe nobody answers.
const Wire = struct {
    link: session_link.Link = undefined,
    io: Stdio = .{},
    fds: [4]std.posix.fd_t = undefined,
    rx: [2 * Env.max_frame]u8 = undefined,
    tx: [Env.max_frame]u8 = undefined,

    fn open(self: *Wire) !void {
        const down = try std.Io.Threaded.pipe2(.{});
        const up = try std.Io.Threaded.pipe2(.{});
        self.fds = .{ down[0], down[1], up[0], up[1] };
        self.io = .{ .input = up[0], .output = down[1] };
        self.link.open(self.io.transport(), &self.rx, &self.tx);
        self.link.state = .{ .connected = .{ .version = proto.protocol_version, .caps = proto.capabilities } };
        self.link.client.peer_caps = proto.capabilities;
    }

    fn close(self: *Wire) void {
        for (self.fds) |fd| std.Io.Threaded.closeFd(fd);
    }
};

fn reply(camera: *Camera, id: u32, ok: bool) void {
    const result: Env.Result = if (ok) .{ .ok = "" } else .{ .err = @fromBackingInt(@intCast(0x0100)) };
    camera.observe(.{ .response = .{ .id = id, .result = result } });
}

test "the spec text is KIND or KIND:ARG, as on the command line" {
    var buffer: [64]u8 = undefined;
    try std.testing.expectEqualStrings("gradient", try shell_camera.specText(&buffer, .{ .kind = .gradient, .arg = "" }));
    try std.testing.expectEqualStrings("image:cat.png", try shell_camera.specText(&buffer, .{ .kind = .image, .arg = "cat.png" }));
    var tiny: [4]u8 = undefined;
    try std.testing.expectError(error.NoSpaceLeft, shell_camera.specText(&tiny, .{ .kind = .webcam, .arg = "" }));
}

test "a pick is asked once while connected, and the answer moves the ring" {
    var wire: Wire = .{};
    try wire.open();
    defer wire.close();
    var camera: Camera = .{ .args = .{ .image = "cat.png" } };
    camera.attach(&wire.link);
    try std.testing.expectEqual(@as(?u32, null), camera.asked);
    camera.panel.pick(.image);
    camera.attach(&wire.link);
    const first = camera.asked.?;
    try std.testing.expectEqual(shell_camera.Status.asking, camera.status);
    camera.attach(&wire.link);
    try std.testing.expectEqual(first, camera.asked.?);
    reply(&camera, first + 1, true);
    try std.testing.expectEqual(shell_camera.Status.asking, camera.status);
    reply(&camera, first, true);
    try std.testing.expectEqual(shell_camera.Status.switched, camera.status);
    try std.testing.expectEqual(gui_app.camera_panel.Kind.image, camera.running);
    camera.panel.pick(.gradient);
    camera.attach(&wire.link);
    reply(&camera, camera.asked.?, false);
    try std.testing.expectEqual(shell_camera.Status.refused, camera.status);
    try std.testing.expectEqual(gui_app.camera_panel.Kind.image, camera.panel.active);
}

test "a source with no file chosen is not asked and the ring goes back" {
    var wire: Wire = .{};
    try wire.open();
    defer wire.close();
    var camera: Camera = .{};
    camera.panel.pick(.video);
    camera.attach(&wire.link);
    try std.testing.expectEqual(@as(?u32, null), camera.asked);
    try std.testing.expectEqual(shell_camera.Status.needs_file, camera.status);
    try std.testing.expectEqual(gui_app.camera_panel.Kind.gradient, camera.panel.active);
    camera.attach(&wire.link);
    try std.testing.expectEqual(@as(?u32, null), camera.asked);
}

test "the webcam is asked only after the panel's consent" {
    var wire: Wire = .{};
    try wire.open();
    defer wire.close();
    var camera: Camera = .{};
    camera.panel.pick(.webcam);
    camera.attach(&wire.link);
    try std.testing.expectEqual(@as(?u32, null), camera.asked);
    camera.panel.answer(.allow_once);
    camera.attach(&wire.link);
    try std.testing.expect(camera.asked != null);
    try std.testing.expectEqual(gui_app.camera_panel.Kind.webcam, camera.asked_kind);
}

fn cameraLayout(gpa: std.mem.Allocator) !pane_layout.Layout {
    var layout = try pane_layout.Layout.init(gpa, .{ .kind = .board, .core = .cpu0 });
    errdefer layout.deinit();
    _ = try layout.split(layout.root, .across, .{ .kind = .camera, .core = .cpu0 });
    return layout;
}

fn cameraBody(layout: *const pane_layout.Layout, solved: *const pane_layout.Solved) !draw_list.Rect {
    for (solved.panes.items) |placed| {
        const pane = layout.pane(placed.index) orelse continue;
        if (pane.kind == .camera) return frame.bodyOf(placed.area);
    }
    return error.NoCameraLeaf;
}

test "a press in the camera leaf picks in its panel; one elsewhere does not" {
    const gpa = std.testing.allocator;
    var layout = try cameraLayout(gpa);
    defer layout.deinit();
    var solved = try frame.solve(&layout, gpa, 480, 320);
    defer solved.deinit(gpa);
    const body = try cameraBody(&layout, &solved);
    const button = shell_camera.layoutIn(body).source(.pipe);
    var camera: Camera = .{};
    try std.testing.expect(!camera.clickIn(&layout, &solved, 1, frame.bodyOf(solved.panes.items[0].area).y + 1));
    try std.testing.expect(camera.clickIn(&layout, &solved, button.x + 1, button.y + 1));
    try std.testing.expectEqual(gui_app.camera_panel.Kind.pipe, camera.panel.active);
}

fn holds(pixels: *const raster.Framebuffer, area: draw_list.Rect, color: draw_list.Color) bool {
    var y = area.y;
    while (y < area.y + area.h) : (y += 1) {
        var x = area.x;
        while (x < area.x + area.w) : (x += 1) {
            if (std.meta.eql(pixels.at(@intCast(x), @intCast(y)), color)) return true;
        }
    }
    return false;
}

test "the camera leaf paints the panel and its note in place of the wait note" {
    const gpa = std.testing.allocator;
    var layout = try cameraLayout(gpa);
    defer layout.deinit();
    var solved = try frame.solve(&layout, gpa, 480, 320);
    defer solved.deinit(gpa);
    const camera: Camera = .{ .status = .refused };
    var list = draw_list.DrawList.init(gpa, 480, 320);
    defer list.deinit();
    const status: status_bar.Status = .{};
    var painter: panes.Panes = .{ .camera = &camera };
    try frame.draw(&list, .{ .layout = &layout, .solved = &solved, .strip = status_capture.strip(&status, .closed), .width = 480, .height = 320, .painter = painter.painter() });
    var pixels = try raster.Framebuffer.init(gpa, 480, 320);
    defer pixels.deinit(gpa);
    raster.draw(&pixels, &list, font.atlas);
    const body = try cameraBody(&layout, &solved);
    const at = shell_camera.layoutIn(body);
    try std.testing.expect(holds(&pixels, at.source(.webcam), camera_view.colorOf(.webcam)));
    try std.testing.expect(holds(&pixels, at.indicator(), camera_view.camera_off));
    const area = at.area();
    const below: draw_list.Rect = .{ .x = body.x, .y = area.y + area.h + frame.pad, .w = body.w, .h = font.glyph_h };
    try std.testing.expect(holds(&pixels, below, frame.muted));
}
