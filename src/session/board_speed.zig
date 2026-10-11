//! The board's side of a session speed change when the session and the
//! engine share one thread, as in the debugger (RA8EMU-184): the change
//! lands on the board's pacing at once, between commands.
const session_api = @import("api.zig");
const clocks = @import("ra8_chip").periph.clocks;
const pacer = @import("run.zig").pacer;
const pacing = @import("run.zig").pacing;

pub const BoardSpeed = struct {
    time: *clocks.Time,
    paced: *?pacing.Pacing,
    clock: pacer.Clock,

    pub fn hook(self: *BoardSpeed) session_api.SpeedHook {
        return .{ .context = self, .setFn = set };
    }

    /// Re-anchor the pacer at the current virtual time, so time carries on
    /// and only its rate against the wall changes; an unpaced board starts
    /// pacing here, and `max` (null) drops the pacer.
    fn set(context: *anyopaque, wanted: ?u64) anyerror!void {
        const self: *BoardSpeed = @ptrCast(@alignCast(context));
        const milli = wanted orelse {
            self.paced.* = null;
            return;
        };
        const now_ns = self.time.base.now();
        if (self.paced.*) |*running| {
            running.setSpeed(now_ns, milli);
        } else {
            self.paced.* = pacing.Pacing.start(self.clock, now_ns, milli);
        }
    }
};
