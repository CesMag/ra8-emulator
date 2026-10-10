//! Covers src/board/run/pacer.zig against a fake clock.
const std = @import("std");
const ra8 = @import("ra8");
const pacer = ra8.board.run.pacer;

const Pacer = pacer.Pacer;
const ms = std.time.ns_per_ms;
const s = std.time.ns_per_s;

/// Wall time only moves when the test says so or the pacer sleeps.
const Fake = struct {
    at: u64 = 0,
    slept: u64 = 0,

    fn clock(self: *Fake) pacer.Clock {
        return .{ .ctx = self, .nowFn = now, .sleepFn = sleep };
    }

    fn now(ctx: *anyopaque) u64 {
        const self: *Fake = @ptrCast(@alignCast(ctx));
        return self.at;
    }

    fn sleep(ctx: *anyopaque, ns: u64) void {
        const self: *Fake = @ptrCast(@alignCast(ctx));
        self.at += ns;
        self.slept += ns;
    }
};

test "a fast host sleeps off its lead so 1x tracks the wall clock" {
    var fake = Fake{};
    var p = Pacer.begin(fake.clock(), 0, pacer.real_time_milli);
    var virtual: u64 = 0;
    // 60 s of virtual time in 10 ms chunks, each taking 1 ms of host time.
    for (0..6000) |_| {
        fake.at += 1 * ms;
        virtual += 10 * ms;
        p.pace(fake.clock(), virtual);
    }
    try std.testing.expectEqual(@as(u64, 60 * s), fake.at);
    const r = p.report(fake.clock(), virtual);
    try std.testing.expectEqual(@as(u64, 1000), r.requested_milli);
    try std.testing.expectEqual(@as(u64, 1000), r.achieved_milli);
    try std.testing.expectEqual(@as(u64, 0), r.drift_ns);
    try std.testing.expectEqual(@as(u64, 54 * s), r.slept_ns);
}

test "a speed factor scales the wall time a run takes" {
    var fake = Fake{};
    var p = Pacer.begin(fake.clock(), 5 * s, 2000);
    p.pace(fake.clock(), 15 * s);
    try std.testing.expectEqual(@as(u64, 5 * s), fake.at);
    p = Pacer.begin(fake.clock(), 0, 500);
    p.pace(fake.clock(), 1 * s);
    try std.testing.expectEqual(@as(u64, 7 * s), fake.at);
    try std.testing.expectEqual(@as(u64, 500), p.report(fake.clock(), 1 * s).achieved_milli);
}

test "a short lag is caught up without sleeping and leaves no drift" {
    var fake = Fake{};
    var p = Pacer.begin(fake.clock(), 0, pacer.real_time_milli);
    fake.at += 50 * ms; // a 10 ms chunk took 50 ms
    p.pace(fake.clock(), 10 * ms);
    try std.testing.expectEqual(@as(u64, 0), fake.slept);
    try std.testing.expectEqual(@as(u64, 40 * ms), p.report(fake.clock(), 10 * ms).drift_ns);
    fake.at += 1 * ms; // a fast chunk eats into the lag without sleeping
    p.pace(fake.clock(), 50 * ms);
    try std.testing.expectEqual(@as(u64, 0), fake.slept);
    fake.at += 1 * ms; // once caught up it is back on schedule
    p.pace(fake.clock(), 100 * ms);
    try std.testing.expectEqual(@as(u64, 100 * ms), fake.at);
    try std.testing.expectEqual(@as(u64, 48 * ms), fake.slept);
    const r = p.report(fake.clock(), 100 * ms);
    try std.testing.expectEqual(@as(u64, 0), r.drift_ns);
    try std.testing.expectEqual(@as(u64, 0), r.slips);
}

test "a stall past the slip limit is written off as drift and re-anchored" {
    var fake = Fake{};
    var p = Pacer.begin(fake.clock(), 0, pacer.real_time_milli);
    fake.at += 2 * s; // the host stalled during a 10 ms chunk
    p.pace(fake.clock(), 10 * ms);
    var r = p.report(fake.clock(), 10 * ms);
    try std.testing.expectEqual(@as(u64, 1), r.slips);
    try std.testing.expectEqual(@as(u64, 2 * s - 10 * ms), r.drift_ns);
    // Afterwards it paces at 1x again from the new anchor, without a burst.
    fake.at += 1 * ms;
    p.pace(fake.clock(), 20 * ms);
    try std.testing.expectEqual(@as(u64, 2 * s + 10 * ms), fake.at);
    r = p.report(fake.clock(), 20 * ms);
    try std.testing.expectEqual(@as(u64, 2 * s - 10 * ms), r.drift_ns);
    try std.testing.expect(r.achieved_milli < 1000);
}

test "a host that can never keep up runs flat out and reports it" {
    var fake = Fake{};
    var p = Pacer.begin(fake.clock(), 0, pacer.real_time_milli);
    var virtual: u64 = 0;
    for (0..100) |_| {
        fake.at += 20 * ms; // every 10 ms chunk takes 20 ms
        virtual += 10 * ms;
        p.pace(fake.clock(), virtual);
    }
    const r = p.report(fake.clock(), virtual);
    try std.testing.expectEqual(@as(u64, 0), fake.slept);
    try std.testing.expectEqual(@as(u64, 500), r.achieved_milli);
    try std.testing.expectEqual(@as(u64, 1 * s), r.drift_ns);
}

test "a zero speed means real time and no wall time reports zero" {
    var fake = Fake{};
    const p = Pacer.begin(fake.clock(), 0, 0);
    try std.testing.expectEqual(@as(u64, 1000), p.speed_milli);
    try std.testing.expectEqual(@as(u64, 0), p.report(fake.clock(), 0).achieved_milli);
}

test "the host clock moves forward" {
    var host = pacer.HostClock.init(std.testing.io);
    const c = host.clock();
    const a = c.now();
    c.sleep(1000);
    try std.testing.expect(c.now() >= a);
}
