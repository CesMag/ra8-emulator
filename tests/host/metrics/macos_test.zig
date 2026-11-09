const std = @import("std");
const metrics = @import("ra8").host.metrics;

test "Mach absolute CPU time converts nonunit ratios without overflow" {
    try std.testing.expectEqual(@as(u64, 500_000_000), try metrics.macos.ticksToNs(12_000_000, 125, 3));
    try std.testing.expectEqual(@as(u64, 123), try metrics.macos.ticksToNs(123, 1, 1));
    try std.testing.expectEqual(std.math.maxInt(u64), try metrics.macos.ticksToNs(std.math.maxInt(u64), 125, 3));
    try std.testing.expectError(error.InvalidTimebase, metrics.macos.ticksToNs(1, 1, 0));
}
