//! Tests for src/session/rtos_stream.zig: incremental, non-blocking readers.
const std = @import("std");
const ra8 = @import("ra8");
const rtos = ra8.session.step_hook;
const Event = rtos.rtos_trace.Event;
const Kind = rtos.rtos_trace.Kind;
const Cursor = rtos.rtos_stream.Cursor;

test "cursor reads switches and ISR events incrementally in order" {
    var trace = rtos.rtos_trace.Trace{};
    var cursor = Cursor{};
    var buffer: [2]Event = undefined;
    try std.testing.expectEqual(@as(usize, 0), cursor.read(&trace, &buffer).len);

    trace.store(0, 11, 0x2000_1000);
    trace.exception(0, 12, .enter, 15);
    const first = cursor.read(&trace, &buffer);
    try std.testing.expectEqual(@as(usize, 2), first.len);
    try std.testing.expectEqual(Kind.switch_to, first[0].kind);
    try std.testing.expectEqual(@as(u64, 11), first[0].when);
    try std.testing.expectEqual(Kind.enter, first[1].kind);
    try std.testing.expectEqual(@as(u64, 12), first[1].when);
    try std.testing.expectEqual(@as(u16, 15), first[1].exception);

    trace.exception(0, 17, .leave, 15);
    const last = cursor.read(&trace, &buffer);
    try std.testing.expectEqual(@as(usize, 1), last.len);
    try std.testing.expectEqual(Kind.leave, last[0].kind);
    try std.testing.expectEqual(@as(u64, 17), last[0].when);
    try std.testing.expectEqual(@as(usize, 0), cursor.read(&trace, &buffer).len);
}

test "a small read buffer leaves later events available" {
    var trace = rtos.rtos_trace.Trace{};
    trace.store(0, 1, 0x2000_1000);
    trace.exception(0, 2, .enter, 15);
    var cursor = Cursor{};
    var buffer: [1]Event = undefined;
    try std.testing.expectEqual(@as(usize, 1), cursor.read(&trace, &buffer).len);
    const later = cursor.read(&trace, &buffer);
    try std.testing.expectEqual(Kind.enter, later[0].kind);
    try std.testing.expectEqual(@as(u64, 2), later[0].when);
}
