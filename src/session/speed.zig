//! A speed change asked through the session (RA8EMU-184, slice 3): the
//! factor as the debugger's run budget and as the pacer's thousandths.
//!
//! One range for both, the one `--speed` already takes (src/chip/periph/time/
//! speed.zig): 0.001x to 1000000x. A factor between thousandths rounds to
//! the nearest one; one that rounds to zero is refused, not paused, since
//! pause is Session.pause.
const std = @import("std");
const speed = @import("run.zig").speed;

/// Where a running engine takes the new factor, in thousandths of real time,
/// or null to run unpaced as `--speed max` does (RA8EMU-714).
pub const Hook = struct {
    context: *anyopaque,
    setFn: *const fn (context: *anyopaque, milli: ?u64) anyerror!void,
};

pub const Error = error{InvalidSpeed};

pub const Change = struct {
    /// Instructions per run command at this factor.
    budget: u64,
    /// The factor in the pacer's unit: 1000 is 1x. Null is `max`: unpaced.
    milli: ?u64,

    /// A factor, or null for `max`, which keeps the default budget and drops
    /// the pacer, the way a run without `--speed` already goes.
    pub fn of(wanted: ?f64, default_budget: u64) Error!Change {
        const factor = wanted orelse return .{ .budget = default_budget, .milli = null };
        if (!(factor > 0)) return Error.InvalidSpeed;
        const milli = @round(factor * 1000);
        if (milli < 1 or milli > @as(f64, @floatFromInt(speed.max_milli))) return Error.InvalidSpeed;
        const scaled = @as(f64, @floatFromInt(default_budget)) * factor;
        return .{ .budget = @intFromFloat(@max(scaled, 1)), .milli = @intFromFloat(milli) };
    }
};
