//! The rtc request (RA8EMU-809): the board's RTC calendar in one snapshot,
//! decoded, for the debugger's time bar.
const rpc = @import("ra8_rpc");
const proto = @import("session_rpc.zig");
const handlers = @import("session_handlers.zig");
const session_rtc = @import("ra8_session").session_rtc;

const Outcome = rpc.Outcome(proto.RtcReport);

/// A server without a clock hook refuses; counters that hold no date come
/// back with `valid` 0 and every date field 0.
pub fn rtc(context: *handlers.Context, args: proto.CoreOnly) Outcome {
    _ = args;
    const clock = context.clock orelse return .{ .err = @fromBackingInt(@intCast(handlers.app_codes.refused)) };
    const raw = clock.counters();
    const found = session_rtc.decode(raw);
    const date = found orelse session_rtc.Calendar{ .year = 0, .month = 0, .day = 0, .hour = 0, .minute = 0, .second = 0 };
    return .{ .ok = .{
        .running = @intFromBool(raw.running),
        .valid = @intFromBool(found != null),
        .year = date.year,
        .month = date.month,
        .day = date.day,
        .hour = date.hour,
        .minute = date.minute,
        .second = date.second,
    } };
}
