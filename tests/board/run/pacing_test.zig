//! Covers src/board/run/pacing.zig against a fake clock.
const std = @import("std");
const ra8 = @import("ra8");
const clocks = ra8.periph.clocks;
const time_policy = ra8.board.run;

const Pacing = time_policy.pacing.Pacing;
const us = std.time.ns_per_us;
const ms = std.time.ns_per_ms;

const Fake = struct {
    at: u64 = 0,
    sleeps: u64 = 0,

    fn clock(self: *Fake) time_policy.pacer.Clock {
        return .{ .ctx = self, .nowFn = now, .sleepFn = sleep };
    }

    fn now(ctx: *anyopaque) u64 {
        const self: *Fake = @ptrCast(@alignCast(ctx));
        return self.at;
    }

    fn sleep(ctx: *anyopaque, ns: u64) void {
        const self: *Fake = @ptrCast(@alignCast(ctx));
        self.at += ns;
        self.sleeps += 1;
    }
};

test "the board's run policy holds no pacing unless a run attaches it" {
    const run: ra8.board.run_policy.RunPolicy = .{};
    try std.testing.expect(run.pacing == null);
}

test "boundaries closer than a step leave the wall clock alone" {
    var fake = Fake{};
    var paced = Pacing.start(fake.clock(), 0, 1000);
    var virtual: u64 = 0;
    for (0..19) |_| {
        virtual += 50 * us;
        paced.after(virtual);
    }
    try std.testing.expectEqual(@as(u64, 0), fake.sleeps);
    virtual += 50 * us;
    paced.after(virtual);
    try std.testing.expectEqual(@as(u64, 1), fake.sleeps);
    try std.testing.expectEqual(@as(u64, 1 * ms), fake.at);
}

test "a second of 50 us boundaries at 1x takes a second in a thousand looks" {
    var fake = Fake{};
    var paced = Pacing.start(fake.clock(), 0, 1000);
    var virtual: u64 = 0;
    for (0..20_000) |_| {
        virtual += 50 * us;
        paced.after(virtual);
    }
    try std.testing.expectEqual(@as(u64, std.time.ns_per_s), fake.at);
    try std.testing.expectEqual(@as(u64, 1000), fake.sleeps);
    const r = paced.report(virtual);
    try std.testing.expectEqual(@as(u64, 1000), r.achieved_milli);
    try std.testing.expectEqual(@as(u64, 0), r.drift_ns);
}

test "pacing a board's time follows its virtual clock" {
    var fake = Fake{};
    var time = clocks.Time{};
    var paced = Pacing.start(fake.clock(), time.base.now(), 1000);
    time.base.advance(5_000_000); // 5 ms at the default 1 GHz
    paced.after(time.base.now());
    try std.testing.expectEqual(@as(u64, 5 * ms), fake.at);
}
