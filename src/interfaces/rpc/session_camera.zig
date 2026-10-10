//! The set_camera_source handler (RA8EMU-795): choose where the CEU's
//! pixels come from over the wire. The text is the `--camera-source`
//! syntax and parses with the same parser, so the two cannot drift. A spec
//! that does not parse is `bad_args`; one the session cannot open is
//! `refused` and the old source stays. A webcam opens only when the client
//! says its user already consented: under --stdio the session's terminal
//! is the wire, so it can never ask there.
const std = @import("std");
const rpc = @import("ra8_rpc");
const proto = @import("session_rpc.zig");
const handlers = @import("session_handlers.zig");
const source_spec = @import("ra8_host").camera.source_spec;

const Ack = rpc.Outcome(proto.Ack);
const refused: Ack = .{ .err = @fromBackingInt(@intCast(handlers.app_codes.refused)) };

pub fn setCameraSource(context: *handlers.Context, args: proto.CameraSource) Ack {
    const camera = context.camera orelse return refused;
    var spec = source_spec.parse(args.text) catch return .{ .err = .bad_args };
    spec.allow_webcam = args.allow_webcam != 0;
    if (spec.kind == .webcam and !spec.allow_webcam) return refused;
    camera.setFn(camera.context, spec) catch |err| {
        std.debug.print("serve: {s}\n", .{@errorName(err)});
        return refused;
    };
    return .{ .ok = .{ .accepted = 1 } };
}
