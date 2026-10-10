//! Covers src/session/session_speed.zig: a session speed change gives the run
//! budget and the pacer's thousandths, in --speed's range (RA8EMU-184).
const std = @import("std");
const ra8 = @import("ra8");
const Change = ra8.session.session_speed.Change;

test "a factor becomes a budget and thousandths" {
    const quarter = try Change.of(0.25, 1_000_000);
    try std.testing.expectEqual(@as(?u64, 250), quarter.milli);
    try std.testing.expectEqual(@as(u64, 250_000), quarter.budget);
    const five = try Change.of(5, 1_000_000);
    try std.testing.expectEqual(@as(?u64, 5000), five.milli);
    try std.testing.expectEqual(@as(u64, 5_000_000), five.budget);
    const finest = try Change.of(0.001, 100);
    try std.testing.expectEqual(@as(?u64, 1), finest.milli);
    try std.testing.expectEqual(@as(u64, 1), finest.budget);
    try std.testing.expectEqual(@as(?u64, 1235), (try Change.of(1.2346, 1)).milli);
}

test "zero, negative, too fine, too fast and not-a-number are refused" {
    const refused = [_]f64{ 0, -1, 0.0004, 1_000_001, std.math.nan(f64), std.math.inf(f64) };
    for (refused) |factor| {
        try std.testing.expectError(error.InvalidSpeed, Change.of(factor, 1_000_000));
    }
    _ = try Change.of(1_000_000, 1_000_000);
}

test "max keeps the default budget and asks for no pacer" {
    const max = try Change.of(null, 1_000_000);
    try std.testing.expectEqual(@as(u64, 1_000_000), max.budget);
    try std.testing.expectEqual(@as(?u64, null), max.milli);
}
