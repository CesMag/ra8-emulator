const std = @import("std");
const linux = @import("ra8").host.metrics.linux;

test "proc parser handles parentheses in command name and byte units" {
    const raw = try linux.parse("1 (worker ) name) R 0 0 0 0 0 0 0 0 0 0 25 50 0 0", "VmRSS:\t12 kB\nVmSize: 90 kB\nVmHWM: 14 kB\nVmSwap: 2 kB\nThreads: 7\n", 100);
    try std.testing.expectEqual(@as(u64, 750_000_000), raw.cpu_ns);
    try std.testing.expectEqual(@as(u64, 12 * 1024), raw.rss);
    try std.testing.expectEqual(@as(u64, 14 * 1024), raw.footprint);
    try std.testing.expectEqual(@as(u64, 90 * 1024), raw.vsz);
    try std.testing.expectEqual(@as(u32, 7), raw.threads);
    try std.testing.expect(raw.swap_available);
    try std.testing.expectError(error.InvalidStat, linux.parse("broken", "", 100));
    try std.testing.expectError(error.Unavailable, linux.parse("1 (x)", "", 0));
}
