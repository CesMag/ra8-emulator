//! Tests for the GLCDC frame boundary in src/chip/periph/glcdc/vsync.zig.
const std = @import("std");
const ra8 = @import("ra8");
const vsync = ra8.chip.periph.glcdc_out.vsync;

const Seen = struct {
    times: [4]u64 = undefined,
    count: usize = 0,

    fn frame(context: *anyopaque, when_ns: u64) void {
        const self: *Seen = @ptrCast(@alignCast(context));
        self.times[self.count] = when_ns;
        self.count += 1;
    }
};

test "nothing is due before the first period ends" {
    var seen = Seen{};
    var boundary = vsync.Vsync{ .sink = .{ .context = &seen, .frame = Seen.frame } };
    boundary.tick(vsync.default_period_ns - 1);
    try std.testing.expectEqual(@as(usize, 0), seen.count);
    try std.testing.expectEqual(@as(u64, 0), boundary.boundaries);
}

test "each ended period hands the sink the time it ended in" {
    var seen = Seen{};
    var boundary = vsync.Vsync{ .sink = .{ .context = &seen, .frame = Seen.frame } };
    boundary.tick(vsync.default_period_ns);
    boundary.tick(vsync.default_period_ns + 5);
    boundary.tick(2 * vsync.default_period_ns + 7);
    try std.testing.expectEqual(@as(usize, 2), seen.count);
    try std.testing.expectEqual(vsync.default_period_ns, seen.times[0]);
    try std.testing.expectEqual(2 * vsync.default_period_ns + 7, seen.times[1]);
    try std.testing.expectEqual(3 * vsync.default_period_ns, boundary.next_ns);
}

test "a long chunk scans once and counts the periods it swallowed" {
    var seen = Seen{};
    var boundary = vsync.Vsync{ .sink = .{ .context = &seen, .frame = Seen.frame } };
    boundary.tick(4 * vsync.default_period_ns + 1);
    try std.testing.expectEqual(@as(usize, 1), seen.count);
    try std.testing.expectEqual(@as(u64, 4), boundary.boundaries);
    try std.testing.expectEqual(@as(u64, 3), boundary.swallowed);
    try std.testing.expectEqual(5 * vsync.default_period_ns, boundary.next_ns);
}

const Settles = struct {
    polls: u32 = 0,
    last: u64 = 0,
    fn frame(_: *anyopaque, _: u64) void {}
    fn settle(context: *anyopaque, now_ns: u64) anyerror!void {
        const self: *Settles = @ptrCast(@alignCast(context));
        self.polls += 1;
        self.last = now_ns;
    }
};

test "settle polls the sink on every chunk, frame boundary or not" {
    var seen = Settles{};
    var boundary = vsync.Vsync{ .sink = .{ .context = &seen, .frame = Settles.frame, .settle = Settles.settle } };
    try boundary.settle(5);
    try boundary.settle(7);
    try std.testing.expectEqual(@as(u32, 2), seen.polls);
    try std.testing.expectEqual(@as(u64, 7), seen.last);
}

test "settle without a poll does nothing" {
    var seen = Settles{};
    var boundary = vsync.Vsync{ .sink = .{ .context = &seen, .frame = Settles.frame } };
    try boundary.settle(5);
    try std.testing.expectEqual(@as(u32, 0), seen.polls);
}
