//! Tests for src/components/esp32c6_hosted/queue.zig.
const std = @import("std");
const ra8 = @import("ra8");
const hosted = ra8.components.esp_hosted;
const frame = hosted.frame;
const queue = hosted.queue;

test "frames leave in the order they were queued" {
    var q: queue.Queue = .{};
    var item: [frame.frame_size]u8 = undefined;
    var out: [frame.frame_size]u8 = undefined;
    try std.testing.expect(q.isEmpty());
    for (0..queue.capacity) |i| {
        @memset(&item, @intCast(i));
        try std.testing.expect(q.push(&item));
    }
    try std.testing.expect(!q.push(&item));
    for (0..queue.capacity) |i| {
        try std.testing.expect(q.pop(&out));
        try std.testing.expectEqual(@as(u8, @intCast(i)), out[frame.frame_size - 1]);
    }
    try std.testing.expect(!q.pop(&out));
    try std.testing.expect(q.isEmpty());
}

test "the queue wraps around its slots" {
    var q: queue.Queue = .{};
    var item: [frame.frame_size]u8 = undefined;
    var out: [frame.frame_size]u8 = undefined;
    for (0..queue.capacity * 3) |i| {
        @memset(&item, @intCast(i));
        try std.testing.expect(q.push(&item));
        try std.testing.expect(q.pop(&out));
        try std.testing.expectEqual(@as(u8, @intCast(i)), out[0]);
    }
}
