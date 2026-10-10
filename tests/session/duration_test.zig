//! Tests for src/session/duration.zig.
const std = @import("std");
const ra8 = @import("ra8");
const duration = ra8.session.duration;

const s: u64 = 1_000_000_000;

test "a duration reads as virtual nanoseconds in s, m, h or d" {
    try std.testing.expectEqual(30 * s, try duration.parse("30s"));
    try std.testing.expectEqual(90 * 60 * s, try duration.parse("90m"));
    try std.testing.expectEqual(12 * 3600 * s, try duration.parse("12h"));
    try std.testing.expectEqual(7 * 24 * 3600 * s, try duration.parse("7d"));
    try std.testing.expectEqual(365 * 24 * 3600 * s, try duration.parse("365d"));
}

test "a bad duration is refused with a reason" {
    try std.testing.expectError(error.NoUnit, duration.parse("90"));
    try std.testing.expectError(error.NotANumber, duration.parse("m"));
    try std.testing.expectError(error.NotANumber, duration.parse("1.5h"));
    try std.testing.expectError(error.NotANumber, duration.parse("7w"));
    try std.testing.expectError(error.NotANumber, duration.parse(""));
    try std.testing.expectError(error.NotPositive, duration.parse("0d"));
    try std.testing.expectError(error.NotPositive, duration.parse("-5m"));
    try std.testing.expectError(error.TooLong, duration.parse("3651d"));
    try std.testing.expectError(error.TooLong, duration.parse("99999999999999999999s"));
    try std.testing.expect(duration.describe(error.NoUnit).len > 0);
}

test "the cycle budget covers the whole duration at the core's rate" {
    try std.testing.expectEqual(@as(u64, 90 * 60 * s), duration.cycles(90 * 60 * s, s));
    try std.testing.expectEqual(@as(u64, 480_000_000), duration.cycles(s, 480_000_000));
    try std.testing.expectEqual(@as(u64, 1), duration.cycles(1, 480_000_000));
    const week = try duration.parse("7d");
    try std.testing.expectEqual(@as(u64, 7 * 24 * 3600 * 200_000_000), duration.cycles(week, 200_000_000));
}
