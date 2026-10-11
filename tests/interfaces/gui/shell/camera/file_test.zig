//! Host tests for the camera leaf's file field (RA8EMU-799): Enter gives the
//! path to the kind that asked for a file, the leaf's next ask carries
//! KIND:PATH, a new path for the running kind opens it again, each kind keeps
//! its own path, nothing happens with no file kind in play, and the leaf
//! draws the field at its foot.
const std = @import("std");
const dark = &@import("gui_app").colors.palettes.dark;
const ra8 = @import("ra8");
const gui_app = @import("gui_app");
const proto = ra8.rpc.session.rpc;
const Stdio = ra8.rpc.stdio_transport.Stdio;
const draw_list = ra8.render.draw_list;
const platform = gui_app.platform;
const session_link = gui_app.session_link;
const shell_camera = gui_app.shell.camera;
const file_field = gui_app.shell.camera.file;
const Kind = gui_app.camera.panel.Kind;
const Camera = shell_camera.Camera;
const CameraFile = file_field.CameraFile;
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

const body: draw_list.Rect = .{ .x = 0, .y = 0, .w = 300, .h = 200 };

/// Draw the leaf once, focus the field, type `path` (8 bytes at most) and
/// press Enter.
fn submit(file: *CameraFile, camera: *const Camera, path: []const u8) !void {
    var list = draw_list.DrawList.init(std.testing.allocator, 300, 200);
    defer list.deinit();
    try file_field.draw(&list, dark, body, camera, file);
    const rect = file_field.fieldRect(body);
    try std.testing.expect(file.press(rect.x + 2, rect.y + 2));
    if (path.len > 0) try std.testing.expect(file.handle(.{ .text = platform.Text.of(path) }));
    _ = file.handle(.{ .key = .{ .code = 0x0D, .down = true } });
}

test "the path goes to the kind waiting for a file, else the running file kind" {
    var camera: Camera = .{};
    try std.testing.expectEqual(@as(?Kind, null), file_field.target(&camera));
    camera.panel.active = .pipe;
    try std.testing.expectEqual(@as(?Kind, .pipe), file_field.target(&camera));
    camera.wants = .video;
    try std.testing.expectEqual(@as(?Kind, .video), file_field.target(&camera));
    camera.wants = null;
    camera.panel.active = .webcam;
    try std.testing.expectEqual(@as(?Kind, null), file_field.target(&camera));
}

test "a path after a pick that needed one switches the session to it" {
    var wire: Wire = .{};
    try wire.open();
    defer wire.close();
    var camera: Camera = .{};
    camera.panel.pick(.video);
    camera.attach(&wire.link);
    try std.testing.expectEqual(shell_camera.Status.needs_file, camera.status);
    try std.testing.expectEqual(@as(?Kind, .video), camera.wants);
    var file: CameraFile = .{};
    try file.init();
    try submit(&file, &camera, "a.y4m");
    try std.testing.expect(file.apply(&camera));
    try std.testing.expectEqualStrings("a.y4m", camera.args.video);
    try std.testing.expectEqual(@as(?Kind, null), camera.wants);
    try std.testing.expectEqualStrings("", file.field.value());
    camera.attach(&wire.link);
    try std.testing.expect(camera.asked != null);
    try std.testing.expectEqual(Kind.video, camera.asked_kind);
    var buffer: [64]u8 = undefined;
    const spec = try gui_app.camera.open.spec(camera.panel, camera.args);
    try std.testing.expectEqualStrings("video:a.y4m", try shell_camera.specText(&buffer, spec));
}

test "a new path for the running kind opens it again" {
    var camera: Camera = .{};
    camera.panel.active = .image;
    camera.running = .image;
    const before = camera.panel.changes;
    var file: CameraFile = .{};
    try file.init();
    try submit(&file, &camera, "dog.png");
    try std.testing.expect(file.apply(&camera));
    try std.testing.expectEqual(before + 1, camera.panel.changes);
    try std.testing.expectEqualStrings("dog.png", camera.args.image);
}

test "each file kind keeps its own path" {
    var camera: Camera = .{};
    var file: CameraFile = .{};
    try file.init();
    camera.wants = .image;
    try submit(&file, &camera, "cat.png");
    try std.testing.expect(file.apply(&camera));
    camera.wants = .pipe;
    try submit(&file, &camera, "-,4x4,y");
    try std.testing.expect(file.apply(&camera));
    try std.testing.expectEqualStrings("cat.png", camera.args.image);
    try std.testing.expectEqualStrings("-,4x4,y", camera.args.pipe);
}

test "Enter does nothing with no file kind in play or an empty field" {
    var camera: Camera = .{};
    var file: CameraFile = .{};
    try file.init();
    try std.testing.expect(!file.apply(&camera));
    try submit(&file, &camera, "x.png");
    try std.testing.expect(!file.apply(&camera));
    try std.testing.expectEqualStrings("x.png", file.field.value());
    try std.testing.expectEqual(@as(u32, 0), camera.panel.changes);
    camera.wants = .image;
    file.field.clear();
    try submit(&file, &camera, "");
    try std.testing.expect(!file.apply(&camera));
}

test "the field sits at the leaf's foot only when it fits under the panel" {
    try std.testing.expect(file_field.fits(body));
    const short: draw_list.Rect = .{ .x = 0, .y = 0, .w = 300, .h = 40 };
    try std.testing.expect(!file_field.fits(short));
    const rect = file_field.fieldRect(body);
    try std.testing.expectEqual(body.y + body.h - gui_app.shell.frame.pad - gui_app.shell.field.height, rect.y);
    const camera: Camera = .{};
    var file: CameraFile = .{};
    try file.init();
    var list = draw_list.DrawList.init(std.testing.allocator, 300, 40);
    defer list.deinit();
    try file_field.draw(&list, dark, short, &camera, &file);
    try std.testing.expect(!file.press(rect.x + 2, rect.y + 2));
}
