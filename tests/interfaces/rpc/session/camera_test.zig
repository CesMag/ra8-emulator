//! Covers the set_camera_source handler (RA8EMU-795): the text parses with
//! the `--camera-source` parser, a bad one is bad_args, a server without a
//! camera hook or a source that will not open is refused, and a webcam is
//! refused unless the client says its user consented.
const std = @import("std");
const ra8 = @import("ra8");

const proto = ra8.rpc.session.rpc;
const handlers = ra8.rpc.session.server;
const camera = ra8.rpc.session.camera;
const source_spec = ra8.host.camera.source_spec;

const Hook = struct {
    calls: u32 = 0,
    last: source_spec.Spec = .{},
    fail: bool = false,

    fn set(context: *anyopaque, spec: source_spec.Spec) anyerror!void {
        const self: *Hook = @ptrCast(@alignCast(context));
        if (self.fail) return error.FileNotFound;
        self.calls += 1;
        self.last = spec;
    }
};

fn contextWith(hook: ?*Hook) handlers.Context {
    var context: handlers.Context = .{ .session = undefined, .scratch = &.{} };
    if (hook) |h| context.camera = .{ .context = h, .setFn = Hook.set };
    return context;
}

fn refusedCode(outcome: anytype) ?u16 {
    return switch (outcome) {
        .ok => null,
        .err => |code| @backingInt(code),
    };
}

test "a parsed spec reaches the hook and is acknowledged" {
    var hook: Hook = .{};
    var context = contextWith(&hook);
    const outcome = camera.setCameraSource(&context, .{ .text = "video:clip.y4m,loop" });
    try std.testing.expectEqual(@as(u8, 1), outcome.ok.accepted);
    try std.testing.expectEqual(@as(u32, 1), hook.calls);
    try std.testing.expectEqual(source_spec.Kind.video, hook.last.kind);
    try std.testing.expectEqualStrings("clip.y4m,loop", hook.last.arg);
    try std.testing.expect(!hook.last.allow_webcam);
}

test "bad text is bad_args; no hook or a failed open is refused" {
    var hook: Hook = .{};
    var context = contextWith(&hook);
    const bad = camera.setCameraSource(&context, .{ .text = "projector" });
    try std.testing.expect(bad == .err and bad.err == .bad_args);
    try std.testing.expectEqual(@as(u32, 0), hook.calls);
    var bare = contextWith(null);
    try std.testing.expectEqual(@as(?u16, handlers.app_codes.refused), refusedCode(camera.setCameraSource(&bare, .{ .text = "gradient" })));
    hook.fail = true;
    try std.testing.expectEqual(@as(?u16, handlers.app_codes.refused), refusedCode(camera.setCameraSource(&context, .{ .text = "gradient" })));
}

test "a webcam needs the client's consent" {
    var hook: Hook = .{};
    var context = contextWith(&hook);
    try std.testing.expectEqual(@as(?u16, handlers.app_codes.refused), refusedCode(camera.setCameraSource(&context, .{ .text = "webcam" })));
    try std.testing.expectEqual(@as(u32, 0), hook.calls);
    const allowed = camera.setCameraSource(&context, .{ .text = "webcam", .allow_webcam = 1 });
    try std.testing.expectEqual(@as(u8, 1), allowed.ok.accepted);
    try std.testing.expect(hook.last.allow_webcam);
}

test "CameraSource round-trips through the codec" {
    var bytes: [600]u8 = undefined;
    const encoded = try proto.encode(proto.CameraSource, .{ .text = "pipe:-,320x240,rgb565", .allow_webcam = 1 }, &bytes);
    const back = try proto.decode(proto.CameraSource, encoded);
    try std.testing.expectEqualStrings("pipe:-,320x240,rgb565", back.text);
    try std.testing.expectEqual(@as(u8, 1), back.allow_webcam);
}
