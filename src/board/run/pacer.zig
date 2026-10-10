//! Real-time pacing (RA8EMU-181, slice 1).
//!
//! The machine runs in short chunks. After each one the pacer compares the
//! virtual time the chunk reached with the host's monotonic clock and sleeps
//! off any lead, so 1x virtual time tracks the wall clock.
//!
//! When the host falls behind, nothing sleeps and the run goes as fast as it
//! can. A short lag is caught up on the next chunks; a lag past `slip_ns` is
//! written off as drift and the pacer re-anchors, so a host stall never turns
//! into a burst of catch-up the guest would see. The drift is never hidden:
//! `report` gives the requested speed, the achieved speed and the total.
//!
//! The clock is passed in, so host tests drive a fake one.
const std = @import("std");

/// One times real time, in thousandths.
pub const real_time_milli: u64 = 1000;

/// A lag past this is written off as drift rather than caught up.
pub const default_slip_ns: u64 = 100 * std.time.ns_per_ms;

/// A monotonic clock in nanoseconds that can also wait.
pub const Clock = struct {
    ctx: *anyopaque,
    nowFn: *const fn (ctx: *anyopaque) u64,
    sleepFn: *const fn (ctx: *anyopaque, ns: u64) void,

    pub fn now(self: Clock) u64 {
        return self.nowFn(self.ctx);
    }

    pub fn sleep(self: Clock, ns: u64) void {
        self.sleepFn(self.ctx, ns);
    }
};

/// What a paced run achieved.
pub const Report = struct {
    requested_milli: u64,
    /// Virtual time over wall time, in thousandths; zero before any wall
    /// time has gone by.
    achieved_milli: u64,
    /// Wall nanoseconds the run is behind its schedule: what was written
    /// off plus any lag still outstanding.
    drift_ns: u64,
    /// How many times the pacer re-anchored after a lag past `slip_ns`.
    slips: u64,
    /// Wall nanoseconds spent waiting for the wall clock.
    slept_ns: u64,
};

pub const Pacer = struct {
    speed_milli: u64 = real_time_milli,
    slip_ns: u64 = default_slip_ns,
    /// The wall and virtual times the schedule counts from.
    anchor_wall: u64 = 0,
    anchor_virtual: u64 = 0,
    /// Where the run started, for the achieved speed.
    start_wall: u64 = 0,
    start_virtual: u64 = 0,
    written_off_ns: u64 = 0,
    slips: u64 = 0,
    slept_ns: u64 = 0,

    /// Start pacing at `virtual_ns`. A zero speed is taken as real time.
    pub fn begin(clock: Clock, virtual_ns: u64, speed_milli: u64) Pacer {
        const wall = clock.now();
        return .{
            .speed_milli = if (speed_milli == 0) real_time_milli else speed_milli,
            .anchor_wall = wall,
            .anchor_virtual = virtual_ns,
            .start_wall = wall,
            .start_virtual = virtual_ns,
        };
    }

    /// Call after each chunk with the virtual time it reached.
    pub fn pace(self: *Pacer, clock: Clock, virtual_ns: u64) void {
        const due = self.dueWall(virtual_ns);
        const at = clock.now();
        if (at < due) {
            clock.sleep(due - at);
            self.slept_ns += due - at;
            return;
        }
        const lag = at - due;
        if (lag <= self.slip_ns) return;
        self.written_off_ns += lag;
        self.slips += 1;
        self.anchor_wall = at;
        self.anchor_virtual = virtual_ns;
    }

    /// Change the factor from here on. The schedule re-anchors at this
    /// moment, so virtual time carries on from where it is, with no jump.
    /// A zero factor is ignored; pausing is the session's (RA8EMU-184).
    pub fn setSpeed(self: *Pacer, clock: Clock, virtual_ns: u64, speed_milli: u64) void {
        if (speed_milli == 0) return;
        const at = clock.now();
        self.written_off_ns += at -| self.dueWall(virtual_ns);
        self.anchor_wall = at;
        self.anchor_virtual = virtual_ns;
        self.speed_milli = speed_milli;
    }

    pub fn report(self: *const Pacer, clock: Clock, virtual_ns: u64) Report {
        const at = clock.now();
        const due = self.dueWall(virtual_ns);
        return .{
            .requested_milli = self.speed_milli,
            .achieved_milli = ratioMilli(
                virtual_ns -| self.start_virtual,
                at -| self.start_wall,
            ),
            .drift_ns = self.written_off_ns + (at -| due),
            .slips = self.slips,
            .slept_ns = self.slept_ns,
        };
    }

    /// The wall time `virtual_ns` is due at on the current schedule.
    fn dueWall(self: *const Pacer, virtual_ns: u64) u64 {
        const ran = virtual_ns -| self.anchor_virtual;
        const wall = @as(u128, ran) * real_time_milli / self.speed_milli;
        return self.anchor_wall + @as(u64, @intCast(@min(wall, std.math.maxInt(u64) - self.anchor_wall)));
    }
};

fn ratioMilli(virtual_ns: u64, wall_ns: u64) u64 {
    if (wall_ns == 0) return 0;
    const r = @as(u128, virtual_ns) * real_time_milli / wall_ns;
    return @intCast(@min(r, std.math.maxInt(u64)));
}

/// The host's monotonic clock: the awake clock, read and slept on through
/// the run's io.
pub const HostClock = struct {
    io: std.Io,
    start: std.Io.Timestamp,

    pub fn init(io: std.Io) HostClock {
        return .{ .io = io, .start = .now(io, .awake) };
    }

    pub fn clock(self: *HostClock) Clock {
        return .{ .ctx = self, .nowFn = nowHost, .sleepFn = sleepHost };
    }

    fn nowHost(ctx: *anyopaque) u64 {
        const self: *HostClock = @ptrCast(@alignCast(ctx));
        const ran = self.start.untilNow(self.io, .awake).nanoseconds;
        return @intCast(std.math.clamp(ran, 0, std.math.maxInt(u64)));
    }

    /// A cancelled sleep wakes early; the pacer reads the clock again and
    /// counts any shortfall as drift, so there is nothing to report.
    fn sleepHost(ctx: *anyopaque, ns: u64) void {
        const self: *HostClock = @ptrCast(@alignCast(ctx));
        self.io.sleep(.fromNanoseconds(ns), .awake) catch {};
    }
};
