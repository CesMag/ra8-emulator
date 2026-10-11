//! The folded handler (RA8EMU-833): a core's sampled call stacks over a
//! virtual-time window, for one thread or all, as the `frames;... count`
//! rows --profile-folded writes. A server that samples nothing, an empty
//! window, or a window and thread that take no sample are refused; rows
//! longer than one reply are `too_long`.
const std = @import("std");
const rpc = @import("ra8_rpc_wire");
const proto = @import("session_rpc.zig");
const handlers = @import("session_handlers.zig");

const Outcome = rpc.Outcome(proto.FoldedText);

pub fn folded(context: *handlers.Context, args: proto.FoldedAsk) Outcome {
    const folding = context.folding orelse return refuse(handlers.app_codes.refused);
    if (args.to_ns <= args.from_ns) return refuse(handlers.app_codes.refused);
    const room = @min(context.scratch.len, proto.FoldedText.max_len.text);
    const thread: ?u32 = if (args.thread == proto.all_threads) null else args.thread;
    const core = @backingInt(args.core);
    const text = folding.foldFn(folding.context, core, thread, args.from_ns, args.to_ns, context.scratch[0..room]) catch |err| {
        if (err == error.NoSpaceLeft or err == error.WriteFailed) return refuse(handlers.app_codes.too_long);
        if (err != error.NothingSampled) std.debug.print("serve: folded: {s}\n", .{@errorName(err)});
        return refuse(handlers.app_codes.refused);
    };
    return .{ .ok = .{ .text = text } };
}

fn refuse(code: u16) Outcome {
    return .{ .err = @fromBackingInt(@intCast(code)) };
}
