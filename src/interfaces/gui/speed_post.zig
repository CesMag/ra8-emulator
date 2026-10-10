//! Hands a speed change from the window to the engine (RA8EMU-184), the
//! way plug_post.zig hands plugs over: the board's pacing is only ever
//! touched on the engine's thread.
//!
//! In a shown run the session's speed hook is `hook()`, so Session.setSpeed
//! leaves the factor here on the window's thread. The engine takes the
//! latest one at its next park and re-anchors the pacer there, so virtual
//! time carries straight on and only its rate against the wall changes. A
//! run that was not paced starts pacing at that park, against `clock`.
const std = @import("std");
const session_api = @import("ra8_session").session_api;
const pacer = @import("ra8_board").run.pacer;
const pacing = @import("ra8_board").run.pacing;

pub const SpeedPost = struct {
    /// Window and engine threads lock through it; neither cancels.
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    /// The latest factor asked for; an older one waiting is dropped, since
    /// only where the slider ended up matters.
    pending: ?Asked = null,

    /// A factor in thousandths, or null for `max`, an unpaced run.
    pub const Asked = struct { milli: ?u64 };

    /// Window side: the session's speed hook, which leaves the factor here.
    pub fn hook(self: *SpeedPost) session_api.SpeedHook {
        return .{ .context = self, .setFn = post };
    }

    fn post(context: *anyopaque, milli: ?u64) anyerror!void {
        const self: *SpeedPost = @ptrCast(@alignCast(context));
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.pending = .{ .milli = milli };
    }

    /// Engine side, at a park: move the run's pacing to the waiting factor
    /// from virtual time `now_ns`. Returns the factor applied, or null when
    /// none was waiting.
    pub fn apply(self: *SpeedPost, paced: *?pacing.Pacing, now_ns: u64, clock: pacer.Clock) ?Asked {
        const asked = self.take() orelse return null;
        const milli = asked.milli orelse {
            paced.* = null;
            return asked;
        };
        if (paced.*) |*running| {
            running.setSpeed(now_ns, milli);
        } else {
            paced.* = pacing.Pacing.start(clock, now_ns, milli);
        }
        return asked;
    }

    fn take(self: *SpeedPost) ?Asked {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const asked = self.pending;
        self.pending = null;
        return asked;
    }
};
