//! The LUT busy status: a refresh that holds the film, the poll that runs it
//! down, and the overlap the model counts rather than invents a refusal for.
const std = @import("std");
const ra8 = @import("ra8");
const busy = ra8.components.eink.busy;

test "a fresh LUT is idle and has nothing to say" {
    var lut = busy.Lut{};
    try std.testing.expect(!lut.busy());
    try std.testing.expect(lut.quiet());
    try std.testing.expectEqual(busy.status.idle, lut.poll());
}

test "a refresh holds the film busy" {
    var lut = busy.Lut{};
    lut.start();
    try std.testing.expect(lut.busy());
    try std.testing.expect(!lut.quiet());
    try std.testing.expectEqual(@as(u32, 1), lut.started);
}

test "the poll is what runs the dwell down" {
    var lut = busy.Lut{};
    lut.start();
    for (0..busy.dwell.refresh) |_| {
        try std.testing.expectEqual(busy.status.busy, lut.poll());
    }
    try std.testing.expect(!lut.busy());
    try std.testing.expectEqual(busy.status.idle, lut.poll());
}

test "the dwell takes exactly its own number of polls" {
    var lut = busy.Lut{};
    lut.start();
    var polls: u32 = 0;
    while (lut.poll() != busy.status.idle) polls += 1;
    try std.testing.expectEqual(busy.dwell.refresh, polls);
}

test "a film polled all the way out counts as settled" {
    var lut = busy.Lut{};
    lut.start();
    while (lut.busy()) _ = lut.poll();
    try std.testing.expectEqual(@as(u32, 1), lut.settled);
    try std.testing.expectEqual(@as(u32, 0), lut.unsettled());
}

test "a refresh nobody waited out is unsettled" {
    var lut = busy.Lut{};
    lut.start();
    try std.testing.expectEqual(@as(u32, 1), lut.unsettled());
}

test "a busy poll and an idle poll are counted apart" {
    var lut = busy.Lut{};
    lut.start();
    _ = lut.poll();
    while (lut.busy()) _ = lut.poll();
    _ = lut.poll();
    try std.testing.expectEqual(busy.dwell.refresh, lut.waited);
    try std.testing.expectEqual(@as(u32, 1), lut.cleared);
}

test "a command on an idle film is not an overlap" {
    var lut = busy.Lut{};
    try std.testing.expect(!lut.arrive());
    try std.testing.expectEqual(@as(u32, 0), lut.overlapped);
}

test "a command on a busy film is counted as one" {
    var lut = busy.Lut{};
    lut.start();
    try std.testing.expect(lut.arrive());
    try std.testing.expectEqual(@as(u32, 1), lut.overlapped);
}

test "an overlapping command is not refused, only counted" {
    var lut = busy.Lut{};
    lut.start();
    _ = lut.arrive();
    try std.testing.expect(lut.busy());
    try std.testing.expectEqual(@as(u32, 1), lut.started);
}

test "a refresh on top of one in flight restarts the dwell" {
    var lut = busy.Lut{};
    lut.start();
    _ = lut.poll();
    _ = lut.poll();
    lut.start();
    var polls: u32 = 0;
    while (lut.poll() != busy.status.idle) polls += 1;
    try std.testing.expectEqual(busy.dwell.refresh, polls);
    try std.testing.expectEqual(@as(u32, 2), lut.started);
}

test "two refreshes each waited out both settle" {
    var lut = busy.Lut{};
    for (0..2) |_| {
        lut.start();
        while (lut.busy()) _ = lut.poll();
    }
    try std.testing.expectEqual(@as(u32, 2), lut.settled);
    try std.testing.expectEqual(@as(u32, 0), lut.unsettled());
}

test "an overlap alone breaks the quiet" {
    var lut = busy.Lut{};
    lut.start();
    while (lut.busy()) _ = lut.poll();
    try std.testing.expect(!lut.quiet());
}

test "unsettled never goes below zero" {
    var lut = busy.Lut{};
    lut.start();
    while (lut.busy()) _ = lut.poll();
    _ = lut.poll();
    _ = lut.poll();
    try std.testing.expectEqual(@as(u32, 0), lut.unsettled());
}

test "the busy word is the one bit the driver reads" {
    var lut = busy.Lut{};
    lut.start();
    try std.testing.expect(lut.poll() != 0);
    try std.testing.expectEqual(@as(u16, 0), busy.status.idle);
}
