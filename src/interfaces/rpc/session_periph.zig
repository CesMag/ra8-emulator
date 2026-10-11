//! The periph handler (RA8EMU-818): the peripheral blocks a core's bus
//! maps, or one block's registers, as text or as JSON. A server without a
//! peripherals hook, or a block no model is paired with, refuses it; a
//! listing longer than one reply is `too_long`.
const std = @import("std");
const rpc = @import("ra8_rpc_wire");
const proto = @import("session_rpc.zig");
const handlers = @import("session_handlers.zig");

const refused = handlers.app_codes.refused;

pub fn periph(context: *handlers.Context, args: proto.PeriphAsk) rpc.Outcome(proto.PeriphText) {
    const peripherals = context.peripherals orelse return .{ .err = @fromBackingInt(@intCast(refused)) };
    const room = @min(context.scratch.len, proto.PeriphText.max_len.text);
    const core = @backingInt(args.core);
    const text = peripherals.listFn(peripherals.context, core, args.block, args.json != 0, context.scratch[0..room]) catch |err| {
        if (err == error.NoSpaceLeft) return .{ .err = @fromBackingInt(@intCast(handlers.app_codes.too_long)) };
        if (err != error.UnknownBlock) std.debug.print("serve: periph: {s}\n", .{@errorName(err)});
        return .{ .err = @fromBackingInt(@intCast(refused)) };
    };
    return .{ .ok = .{ .text = text } };
}
