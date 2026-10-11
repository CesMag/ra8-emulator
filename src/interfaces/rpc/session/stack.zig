//! The stack request (RA8EMU-816): a core's MSP and PSP, the lowest each
//! reached since reset, and how far the lowest MSP went past the main
//! stack reservation of the image the core last loaded.
const rpc = @import("ra8_rpc_wire");
const proto = @import("rpc.zig");
const handlers = @import("handlers.zig");
const api = @import("ra8_session").api;
const region_map = @import("ra8_session").region.map;
const stack_low = @import("ra8_session").stack.low;

const Outcome = rpc.Outcome(proto.StackReport);

pub fn stack(context: *handlers.Context, args: proto.CoreOnly) Outcome {
    const which: api.Core = @fromBackingInt(@intCast(@backingInt(args.core)));
    const view = context.session.view(which) catch |err| return refuse(err);
    const report: stack_low.Report = .{ .marks = view.stack(), .stack = reservation(context, which) };
    const marks = report.marks;
    const found = report.stack orelse region_map.Stack{ .base = 0, .size = 0, .region = null };
    return .{ .ok = .{
        .core = args.core,
        .msp = marks.msp,
        .psp = marks.psp,
        .low_msp = marks.low_msp,
        .low_psp = marks.low_psp,
        .has_stack = @intFromBool(report.stack != null),
        .base = found.base,
        .size = found.size,
        .overflow = report.overflowBytes(),
    } };
}

/// The reservation the serving side found in the core's image, if any.
fn reservation(context: *handlers.Context, core: api.Core) ?region_map.Stack {
    const mapping = context.mapping orelse return null;
    const stackFn = mapping.stackFn orelse return null;
    return stackFn(mapping.context, @backingInt(core));
}

fn refuse(err: anyerror) Outcome {
    if (err == error.CoreNotAttached) return .{ .err = @fromBackingInt(@intCast(handlers.app_codes.no_core)) };
    return .{ .err = @fromBackingInt(@intCast(handlers.app_codes.refused)) };
}
