//! The wall clock the shell paces a run and times a frame against
//! (RA8EMU-1118): nanoseconds on the host's monotonic clock since the clock
//! was made. It is a seam: the application reads the host's clock through
//! its io, and a test hands in a clock it moves itself.
const std = @import("std");

pub const Clock = struct {
    context: *anyopaque,
    nowFn: *const fn (context: *anyopaque) u64,

    pub fn now(self: Clock) u64 {
        return self.nowFn(self.context);
    }
};

/// The host's awake clock, read through the application's io.
pub const Host = struct {
    io: std.Io,
    start: std.Io.Timestamp,

    pub fn init(io: std.Io) Host {
        return .{ .io = io, .start = .now(io, .awake) };
    }

    /// The clock points at this `Host`, so it must not move.
    pub fn clock(self: *Host) Clock {
        return .{ .context = self, .nowFn = read };
    }

    fn read(context: *anyopaque) u64 {
        const self: *Host = @ptrCast(@alignCast(context));
        const ran = self.start.untilNow(self.io, .awake).nanoseconds;
        return @intCast(std.math.clamp(ran, 0, std.math.maxInt(u64)));
    }
};
