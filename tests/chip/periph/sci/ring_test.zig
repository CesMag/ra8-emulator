//! Covers src/chip/periph/sci/ring.zig: a channel's receive ring and the overrun
//! it reports when it cannot hold what the line drove.
const std = @import("std");
const ra8 = @import("ra8");
const sci_ring = ra8.chip.periph.sci_ring;

test "bytes come back out in the order they went in" {
    var ring = sci_ring.Ring{};
    try std.testing.expect(ring.empty());
    try std.testing.expect(!ring.push("OK"));
    try std.testing.expect(!ring.empty());
    try std.testing.expectEqual(@as(?u8, 'O'), ring.pop());
    try std.testing.expectEqual(@as(?u8, 'K'), ring.pop());
    try std.testing.expectEqual(@as(?u8, null), ring.pop());
    try std.testing.expect(ring.empty());
}

test "a push that fits reports no overrun" {
    var ring = sci_ring.Ring{};
    var block: [sci_ring.limits.rx_queue - 1]u8 = undefined;
    @memset(&block, 'x');
    try std.testing.expect(!ring.push(&block));
    try std.testing.expectEqual(@as(u32, 0), ring.dropped);
}

test "a push past the end reports the overrun and counts what it lost" {
    var ring = sci_ring.Ring{};
    var block: [sci_ring.limits.rx_queue + 3]u8 = undefined;
    @memset(&block, 'y');
    try std.testing.expect(ring.push(&block));
    // One slot stays open to tell full from empty, so four bytes are lost.
    try std.testing.expectEqual(@as(u32, 4), ring.dropped);
}

test "a full ring keeps what it already had" {
    var ring = sci_ring.Ring{};
    var block: [sci_ring.limits.rx_queue - 1]u8 = undefined;
    @memset(&block, 'a');
    _ = ring.push(&block);
    try std.testing.expect(ring.push("z"));
    try std.testing.expectEqual(@as(?u8, 'a'), ring.pop());
    try std.testing.expectEqual(@as(u32, 1), ring.dropped);
}

test "draining makes room again" {
    var ring = sci_ring.Ring{};
    var block: [sci_ring.limits.rx_queue - 1]u8 = undefined;
    @memset(&block, 'b');
    _ = ring.push(&block);
    _ = ring.pop();
    try std.testing.expect(!ring.push("c"));
}

test "a full ring drops the rest instead of wrapping over unread bytes" {
    var ring = sci_ring.Ring{};
    var payload: [sci_ring.limits.rx_queue]u8 = undefined;
    @memset(&payload, 'x');
    try std.testing.expect(ring.push(&payload));
    try std.testing.expectEqual(@as(u32, 1), ring.dropped);
    try std.testing.expectEqual(@as(u8, 'x'), ring.pop().?);
}
