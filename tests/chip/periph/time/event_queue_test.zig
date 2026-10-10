//! Covers src/chip/periph/time/event_queue.zig: ordering, ties, cancel, full.
const std = @import("std");
const ra8 = @import("ra8");
const queue = ra8.chip.periph.clocks.event_queue;

test "events come out in time order, and only once due" {
    var q = queue.EventQueue{};
    try q.schedule(300, 3);
    try q.schedule(100, 1);
    try q.schedule(200, 2);
    try std.testing.expectEqual(@as(?u64, 100), q.next());
    try std.testing.expect(q.popDue(99) == null);
    try std.testing.expectEqual(@as(u16, 1), q.popDue(250).?.id);
    try std.testing.expectEqual(@as(u16, 2), q.popDue(250).?.id);
    try std.testing.expect(q.popDue(250) == null);
    try std.testing.expectEqual(@as(u16, 3), q.popDue(300).?.id);
    try std.testing.expect(q.next() == null);
}

test "events at the same time come out in the order they were scheduled" {
    var q = queue.EventQueue{};
    try q.schedule(50, 7);
    try q.schedule(50, 4);
    try q.schedule(50, 9);
    try std.testing.expectEqual(@as(u16, 7), q.popDue(50).?.id);
    try std.testing.expectEqual(@as(u16, 4), q.popDue(50).?.id);
    try std.testing.expectEqual(@as(u16, 9), q.popDue(50).?.id);
}

test "cancel drops every event under an id" {
    var q = queue.EventQueue{};
    try q.schedule(10, 1);
    try q.schedule(20, 2);
    try q.schedule(30, 1);
    try std.testing.expectEqual(@as(usize, 2), q.cancel(1));
    try std.testing.expectEqual(@as(u16, 2), q.popDue(100).?.id);
    try std.testing.expect(q.popDue(100) == null);
}

test "a full queue refuses rather than dropping an event" {
    var q = queue.EventQueue{};
    for (0..queue.capacity) |i| try q.schedule(i, @intCast(i));
    try std.testing.expectError(error.QueueFull, q.schedule(0, 99));
    try std.testing.expectEqual(@as(u16, 0), q.popDue(0).?.id);
}
