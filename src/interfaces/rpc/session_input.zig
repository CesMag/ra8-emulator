//! The input request (RA8EMU-810): queue a tap, swipe, long press or
//! button press on the board's input script at a virtual board time, so the
//! debugger's board pane can press a button or touch the panel.
const std = @import("std");
const rpc = @import("ra8_rpc_wire");
const proto = @import("session_rpc.zig");
const handlers = @import("session_handlers.zig");
const api = @import("ra8_session").api;
const gt911 = @import("ra8_components").gt911;

const Ack = rpc.Outcome(proto.Ack);

/// An unknown button is bad_args; a session without an input script, an
/// event already in the past or a full queue is refused.
pub fn input(context: *handlers.Context, args: proto.ScheduleInput) Ack {
    const session = context.session;
    const which: api.Core = @fromBackingInt(@intCast(@backingInt(args.core)));
    const at = args.at_ns;
    const from: gt911.Contact = .{ .x = args.x, .y = args.y };
    const queued = switch (args.kind) {
        .tap => session.tap(which, at, args.x, args.y),
        .swipe => session.swipe(which, at, from, .{ .x = args.to_x, .y = args.to_y }, args.duration_ns),
        .longpress => session.longpress(which, at, from, args.duration_ns),
        .button => session.button(which, at, buttonOf(args.button) orelse return .{ .err = .bad_args }),
    };
    queued catch |err| return refuse(err);
    return .{ .ok = .{ .accepted = 1 } };
}

fn buttonOf(id: u8) ?api.Button {
    return switch (id) {
        0 => .sw1,
        1 => .sw2,
        else => null,
    };
}

fn refuse(err: anyerror) Ack {
    std.debug.print("serve: {s}\n", .{@errorName(err)});
    if (err == error.CoreNotAttached) return .{ .err = @fromBackingInt(@intCast(handlers.app_codes.no_core)) };
    return .{ .err = @fromBackingInt(@intCast(handlers.app_codes.refused)) };
}
