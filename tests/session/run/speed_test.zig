//! Covers src/session/run/speed.zig and Pacer.setSpeed (RA8EMU-184).
const std = @import("std");
const ra8 = @import("ra8");
const clocks = ra8.chip.periph.clocks;
const time_policy = ra8.session.run;

const speed = time_policy.speed;
const Pacer = time_policy.pacer.Pacer;
const ms = std.time.ns_per_ms;

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

test "factors read as thousandths of real time" {
    try std.testing.expectEqual(@as(?u64, 100), try speed.parse("0.1"));
    try std.testing.expectEqual(@as(?u64, 250), try speed.parse("0.25"));
    try std.testing.expectEqual(@as(?u64, 1000), try speed.parse("1"));
    try std.testing.expectEqual(@as(?u64, 5000), try speed.parse("5"));
    try std.testing.expectEqual(@as(?u64, 100_000), try speed.parse("100"));
    try std.testing.expectEqual(@as(?u64, 500), try speed.parse(".5"));
    try std.testing.expectEqual(@as(?u64, 2000), try speed.parse("2."));
    try std.testing.expectEqual(@as(?u64, 1), try speed.parse("0.001"));
}

test "max is an unpaced run" {
    try std.testing.expectEqual(@as(?u64, null), try speed.parse("max"));
}

test "zero, negative, text and over-fine factors are refused" {
    try std.testing.expectError(error.NotPositive, speed.parse("0"));
    try std.testing.expectError(error.NotPositive, speed.parse("0.000"));
    try std.testing.expectError(error.NotPositive, speed.parse("-1"));
    try std.testing.expectError(error.NotANumber, speed.parse("fast"));
    try std.testing.expectError(error.NotANumber, speed.parse(""));
    try std.testing.expectError(error.NotANumber, speed.parse("."));
    try std.testing.expectError(error.NotANumber, speed.parse("1x"));
    try std.testing.expectError(error.TooFine, speed.parse("0.0001"));
    try std.testing.expectError(error.TooFast, speed.parse("1000001"));
    try std.testing.expectError(error.TooFast, speed.parse("99999999999999999999999"));
}

test "every refusal has words for the user" {
    for ([_]speed.Error{ error.NotANumber, error.NotPositive, error.TooFine, error.TooFast }) |err| {
        try std.testing.expect(speed.describe(err).len > 0);
    }
}

test "a mid-run speed change keeps virtual time where it is" {
    var fake = Fake{};
    var pacer = Pacer.begin(fake.clock(), 0, 1000);
    pacer.pace(fake.clock(), 10 * ms);
    try std.testing.expectEqual(@as(u64, 10 * ms), fake.at);
    pacer.setSpeed(fake.clock(), 10 * ms, 5000);
    pacer.pace(fake.clock(), 20 * ms);
    try std.testing.expectEqual(@as(u64, 12 * ms), fake.at);
    pacer.setSpeed(fake.clock(), 20 * ms, 250);
    pacer.pace(fake.clock(), 21 * ms);
    try std.testing.expectEqual(@as(u64, 16 * ms), fake.at);
    try std.testing.expectEqual(@as(u64, 0), pacer.report(fake.clock(), 21 * ms).drift_ns);
    try std.testing.expectEqual(@as(u64, 250), pacer.speed_milli);
}

test "a zero factor leaves the pacer as it was" {
    var fake = Fake{};
    var pacer = Pacer.begin(fake.clock(), 0, 2000);
    pacer.setSpeed(fake.clock(), 0, 0);
    try std.testing.expectEqual(@as(u64, 2000), pacer.speed_milli);
}
