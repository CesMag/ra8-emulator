//! Covers src/interfaces/gui/speed_post.zig: a speed change the window leaves for the
//! engine, applied to the board's pacing at a park, against a fake clock.
const std = @import("std");
const ra8 = @import("ra8");

const clocks = ra8.periph.clocks;
const time_policy = ra8.board.run;
const SpeedPost = ra8.gui.speed_post.SpeedPost;
const us = std.time.ns_per_us;
const ms = std.time.ns_per_ms;
const s = std.time.ns_per_s;

const Fake = struct {
    at: u64 = 0,

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
    }
};

/// A board time whose cycles are nanoseconds, with the pacing a run
/// attaches beside it.
const Run = struct {
    base: clocks.timebase.TimeBase = .{},
    pacing: ?time_policy.pacing.Pacing = null,

    fn park(self: *Run, post: *SpeedPost, clock: time_policy.pacer.Clock) ?SpeedPost.Asked {
        return post.apply(&self.pacing, self.base.now(), clock);
    }
};

fn nanoTime() Run {
    var time = Run{};
    time.base.setRate(std.time.ns_per_s);
    return time;
}

/// Run `span` of virtual time in 50 us chunks, pacing at each boundary.
fn runFor(time: *Run, span: u64) void {
    var done: u64 = 0;
    while (done < span) : (done += 50 * us) {
        time.base.advance(50 * us);
        if (time.pacing) |*pacing| pacing.after(time.base.now());
    }
}

fn ask(post: *SpeedPost, milli: ?u64) !void {
    const hook = post.hook();
    try hook.setFn(hook.context, milli);
}

test "a park with nothing waiting leaves the time alone" {
    var fake = Fake{};
    var time = nanoTime();
    var post = SpeedPost{ .io = std.testing.io };
    try std.testing.expectEqual(@as(?SpeedPost.Asked, null), time.park(&post, fake.clock()));
    try std.testing.expect(time.pacing == null);
}

test "a change waiting for an unpaced run starts pacing at that factor" {
    var fake = Fake{};
    var time = nanoTime();
    var post = SpeedPost{ .io = std.testing.io };
    runFor(&time, 1 * s);
    try ask(&post, 5000);
    try std.testing.expectEqual(@as(?SpeedPost.Asked, .{ .milli = 5000 }), time.park(&post, fake.clock()));
    try std.testing.expectEqual(@as(u64, 1 * s), time.base.now());
    runFor(&time, 1 * s);
    try std.testing.expectEqual(@as(u64, 200 * ms), fake.at);
    try std.testing.expectEqual(@as(?SpeedPost.Asked, null), time.park(&post, fake.clock()));
}

test "1x to 5x mid-run keeps virtual time and pays only the new rate" {
    var fake = Fake{};
    var time = nanoTime();
    time.pacing = time_policy.pacing.Pacing.start(fake.clock(), 0, 1000);
    var post = SpeedPost{ .io = std.testing.io };
    runFor(&time, 1 * s);
    try std.testing.expectEqual(@as(u64, 1 * s), fake.at);
    try ask(&post, 2000);
    try ask(&post, 5000);
    try std.testing.expectEqual(@as(?SpeedPost.Asked, .{ .milli = 5000 }), time.park(&post, fake.clock()));
    try std.testing.expectEqual(@as(u64, 1 * s), time.base.now());
    runFor(&time, 1 * s);
    try std.testing.expectEqual(@as(u64, 1200 * ms), fake.at);
    const r = time.pacing.?.report(time.base.now());
    try std.testing.expectEqual(@as(u64, 5000), r.requested_milli);
    try std.testing.expectEqual(@as(u64, 0), r.drift_ns);
}

test "max waiting for a paced run drops the pacer" {
    var fake = Fake{};
    var time = nanoTime();
    time.pacing = time_policy.pacing.Pacing.start(fake.clock(), 0, 1000);
    var post = SpeedPost{ .io = std.testing.io };
    try ask(&post, null);
    try std.testing.expectEqual(@as(?SpeedPost.Asked, .{ .milli = null }), time.park(&post, fake.clock()));
    try std.testing.expect(time.pacing == null);
}
