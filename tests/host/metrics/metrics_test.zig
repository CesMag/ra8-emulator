const std = @import("std");
const metrics = @import("ra8").host.metrics;

test "process CPU uses elapsed time, normalizes cores and retains peak" {
    var sampler: metrics.Sampler = .{};
    sampler.record(.{ .cpu_ns = 1_000_000_000, .cores = 4, .footprint = 300 }, 1_000_000_000);
    try std.testing.expectEqual(@as(f64, 0), sampler.current.?.cpu_percent);
    sampler.record(.{ .cpu_ns = 2_000_000_000, .cores = 4, .footprint = 100 }, 1_500_000_000);
    const sample = sampler.current.?;
    try std.testing.expectEqual(@as(f64, 200), sample.cpu_percent);
    try std.testing.expectEqual(@as(f64, 50), sample.cpu_total_percent);
    try std.testing.expectEqual(@as(u64, 300), sample.peak_footprint);
}

test "history rolls in chronological order and counter reset is safe" {
    var sampler: metrics.Sampler = .{};
    for (0..metrics.capacity + 5) |i| sampler.record(.{ .cpu_ns = i * 100, .footprint = i }, i * 1000);
    try std.testing.expectEqual(metrics.capacity, sampler.count);
    try std.testing.expectEqual(@as(u64, 5), sampler.at(0).footprint);
    try std.testing.expectEqual(@as(u64, metrics.capacity + 4), sampler.at(metrics.capacity - 1).footprint);
    sampler.record(.{ .cpu_ns = 0 }, 200_000);
    try std.testing.expectEqual(@as(f64, 0), sampler.current.?.cpu_percent);
}

test "live host sampler supplies memory and threads" {
    var sampler: metrics.Sampler = .{};
    sampler.refresh(1_000_000_000);
    try std.testing.expect(sampler.available);
    try std.testing.expect(sampler.current.?.rss > 0);
    try std.testing.expect(sampler.current.?.threads > 0);
    sampler.refresh(1_100_000_000);
    try std.testing.expectEqual(@as(usize, 1), sampler.count);
}

fn processCpu(usage: std.c.rusage) u64 {
    return @as(u64, @intCast(usage.utime.sec + usage.stime.sec)) * 1_000_000_000 +
        @as(u64, @intCast(usage.utime.usec + usage.stime.usec)) * 1000;
}

test "Darwin process CPU counter agrees with getrusage across real work" {
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    var usage: std.c.rusage = undefined;
    var sampler: metrics.Sampler = .{};
    sampler.refresh(0);
    try std.testing.expectEqual(@as(c_int, 0), std.c.getrusage(0, &usage));
    const before = processCpu(usage);
    const began = std.Io.Timestamp.now(std.testing.io, .awake);
    var elapsed: u64 = 0;
    var work: u64 = 1;
    while (elapsed < metrics.interval_ns) {
        for (0..10000) |_| work = work *% 6364136223846793005 +% 1;
        std.mem.doNotOptimizeAway(work);
        elapsed = @intCast(began.untilNow(std.testing.io, .awake).nanoseconds);
    }
    sampler.refresh(elapsed);
    try std.testing.expectEqual(@as(c_int, 0), std.c.getrusage(0, &usage));
    const cpu_ns = processCpu(usage) - before;
    const reported_ns = sampler.current.?.cpu_percent * @as(f64, @floatFromInt(elapsed)) / 100;
    try std.testing.expectApproxEqAbs(@as(f64, @floatFromInt(cpu_ns)), reported_ns, 20_000_000);
    try std.testing.expect(cpu_ns > 0);
    try std.testing.expect(sampler.current.?.rss <= @as(u64, @intCast(usage.maxrss)) + 65536);
    try std.testing.expect(sampler.current.?.cpu_total_percent <= sampler.current.?.cpu_percent);
    std.debug.print("native CPU evidence: getrusage={d}ns sampled={d:.0}ns RSS={d} peakRSS={d}\n", .{ cpu_ns, reported_ns, sampler.current.?.rss, usage.maxrss });
}
