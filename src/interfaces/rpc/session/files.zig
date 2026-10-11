//! The snapshot and restore handlers (RA8EMU-768): the harness's run file
//! over the wire. Paths are read and written on the serving host. A server
//! with no state hook, or a session with CPU1 attached, refuses.
const std = @import("std");
const rpc = @import("ra8_rpc_wire");
const proto = @import("rpc.zig");
const handlers = @import("handlers.zig");

const Context = handlers.Context;
const Ack = rpc.Outcome(proto.Ack);
const ack: Ack = .{ .ok = .{ .accepted = 1 } };

fn refused(err: anyerror) Ack {
    std.debug.print("serve: {s}\n", .{@errorName(err)});
    return .{ .err = @fromBackingInt(@intCast(handlers.app_codes.refused)) };
}

/// Write the whole run to `path`.
pub fn snapshot(context: *Context, args: proto.StatePath) Ack {
    const files = context.state orelse return refused(error.NoStateFiles);
    files.save(args.path) catch |err| return refused(err);
    return ack;
}

/// Put the run back as `path` holds it. A stop still owed to the client
/// belongs to the run that was replaced, so it is dropped.
pub fn restore(context: *Context, args: proto.StatePath) Ack {
    const files = context.state orelse return refused(error.NoStateFiles);
    files.restore(args.path) catch |err| return refused(err);
    context.pending = null;
    return ack;
}
