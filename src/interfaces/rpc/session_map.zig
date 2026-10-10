//! The map handler (RA8EMU-794): the memory map of the image a core last
//! loaded, as the text `--map` prints or as one JSON object. A server
//! without a map hook, or a core with no image, refuses it; a map longer
//! than one reply is `too_long`.
const std = @import("std");
const rpc = @import("ra8_rpc_wire");
const proto = @import("session_rpc.zig");
const handlers = @import("session_handlers.zig");

const refused = handlers.app_codes.refused;

pub fn map(context: *handlers.Context, args: proto.MapAsk) rpc.Outcome(proto.MapText) {
    const mapping = context.mapping orelse return .{ .err = @fromBackingInt(@intCast(refused)) };
    const room = @min(context.scratch.len, proto.MapText.max_len.text);
    const core = @backingInt(args.core);
    const text = mapping.mapFn(mapping.context, core, args.json != 0, context.scratch[0..room]) catch |err| {
        if (err == error.NoSpaceLeft) return .{ .err = @fromBackingInt(@intCast(handlers.app_codes.too_long)) };
        std.debug.print("serve: map: {s}\n", .{@errorName(err)});
        return .{ .err = @fromBackingInt(@intCast(refused)) };
    };
    return .{ .ok = .{ .text = text } };
}
