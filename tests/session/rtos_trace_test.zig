//! Tests for src/session/rtos_trace.zig: stores to the ThreadX
//! current-thread pointer turned into switch and idle events.
const std = @import("std");
const ra8 = @import("ra8");
const rtos_trace = ra8.session.step_hook.rtos_trace;

test "a new thread pointer is a switch, zero is idle" {
    var trace = rtos_trace.Trace{};
    trace.store(0, 10, 0x2200_1000);
    trace.store(0, 25, 0);
    trace.store(0, 40, 0x2200_2000);
    const got = trace.list();
    try std.testing.expectEqual(@as(usize, 3), got.len);
    try std.testing.expectEqual(rtos_trace.Kind.switch_to, got[0].kind);
    try std.testing.expectEqual(@as(u32, 0x2200_1000), got[0].thread);
    try std.testing.expectEqual(@as(u64, 10), got[0].when);
    try std.testing.expectEqual(rtos_trace.Kind.idle, got[1].kind);
    try std.testing.expectEqual(@as(u64, 25), got[1].when);
    try std.testing.expectEqual(@as(u32, 0x2200_2000), got[2].thread);
}

test "storing the thread already running is not a switch" {
    var trace = rtos_trace.Trace{};
    trace.store(0, 1, 0x2200_1000);
    trace.store(0, 2, 0x2200_1000);
    trace.store(0, 3, 0x2200_1000);
    try std.testing.expectEqual(@as(usize, 1), trace.list().len);
}

test "each core keeps its own running thread" {
    var trace = rtos_trace.Trace{};
    trace.store(0, 1, 0x2200_1000);
    trace.store(1, 2, 0x2200_1000);
    trace.store(1, 3, 0x2200_1000);
    var room: [4]rtos_trace.Event = undefined;
    try std.testing.expectEqual(@as(usize, 2), trace.list().len);
    const second = trace.onCore(1, &room);
    try std.testing.expectEqual(@as(usize, 1), second.len);
    try std.testing.expectEqual(@as(u64, 2), second[0].when);
}

test "a full trace keeps the opening and counts the rest" {
    var trace = rtos_trace.Trace{};
    const extra: usize = 5;
    for (0..rtos_trace.limits.kept + extra) |n| {
        trace.store(0, n, @intCast(n + 1));
    }
    try std.testing.expectEqual(rtos_trace.limits.kept, trace.list().len);
    try std.testing.expectEqual(extra, trace.dropped);
    try std.testing.expectEqual(@as(u32, 1), trace.list()[0].thread);
}
