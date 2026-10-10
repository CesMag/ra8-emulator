//! Tests for src/session/rtos_publish.zig: RTOS events on the session stream.
const std = @import("std");
const ra8 = @import("ra8");
const rtos = ra8.session.step_hook;
const stream_mod = ra8.session.session_event_stream;
const Publisher = rtos.rtos_publish.Publisher;

const Counter = struct {
    ticked: u64 = 0,
    fn tick(context: *anyopaque, instructions: u32) anyerror!void {
        const self: *Counter = @ptrCast(@alignCast(context));
        self.ticked += instructions;
    }
};

fn expectRtos(event: stream_mod.Event, kind: stream_mod.Event.Kind, core: stream_mod.Core, when: u64, thread: u32, exception: u16) !void {
    try std.testing.expectEqual(kind, event.kind);
    try std.testing.expectEqual(core, event.core);
    try std.testing.expectEqual(when, event.virtual_ns);
    try std.testing.expectEqual(thread, event.payload.rtos.thread);
    try std.testing.expectEqual(exception, event.payload.rtos.exception);
}

test "a subscriber receives switch and ISR events in order with their stamps" {
    var trace = rtos.rtos_trace.Trace{};
    var stream = stream_mod.Stream{};
    const id = stream.subscribe().?;
    var counter = Counter{};
    var publisher = Publisher{ .trace = &trace, .stream = &stream, .inner = .{ .context = &counter, .tickFn = Counter.tick, .chunk = 64 } };
    const edge = publisher.hook();
    try std.testing.expectEqual(@as(u32, 64), edge.chunk);

    trace.store(0, 100, 0x2000_1000);
    trace.exception(0, 140, .enter, 15);
    trace.exception(0, 180, .leave, 15);
    try edge.tickFn(edge.context, 64);
    trace.store(1, 220, 0);
    try edge.tickFn(edge.context, 32);
    try std.testing.expectEqual(@as(u64, 96), counter.ticked);

    var out: [8]stream_mod.Event = undefined;
    const read = stream.read(id, &out).?;
    try std.testing.expectEqual(@as(usize, 4), read.count);
    try std.testing.expectEqual(@as(u64, 0), read.dropped);
    try expectRtos(out[0], .rtos_switch, .cpu0, 100, 0x2000_1000, 0);
    try expectRtos(out[1], .isr_enter, .cpu0, 140, 0, 15);
    try expectRtos(out[2], .isr_leave, .cpu0, 180, 0, 15);
    try expectRtos(out[3], .rtos_idle, .cpu1, 220, 0, 0);
}

test "a drain publishes each event once, past one read batch" {
    var trace = rtos.rtos_trace.Trace{};
    var stream = stream_mod.Stream{};
    const id = stream.subscribe().?;
    var publisher = Publisher{ .trace = &trace, .stream = &stream };
    const total = rtos.rtos_publish.batch + 5;
    for (0..total) |i| trace.exception(0, i, .enter, @intCast(16 + i));
    publisher.drain();
    publisher.drain();
    var out: [stream_mod.capacity]stream_mod.Event = undefined;
    const read = stream.read(id, &out).?;
    try std.testing.expectEqual(@as(usize, total), read.count);
    for (out[0..read.count], 0..) |event, i| try expectRtos(event, .isr_enter, .cpu0, i, 0, @intCast(16 + i));
}

test "with no inner boundary the hook still drains" {
    var trace = rtos.rtos_trace.Trace{};
    var stream = stream_mod.Stream{};
    const id = stream.subscribe().?;
    var publisher = Publisher{ .trace = &trace, .stream = &stream };
    const edge = publisher.hook();
    trace.store(0, 7, 0x2000_2000);
    try edge.tickFn(edge.context, 1);
    var out: [2]stream_mod.Event = undefined;
    try std.testing.expectEqual(@as(usize, 1), stream.read(id, &out).?.count);
    try expectRtos(out[0], .rtos_switch, .cpu0, 7, 0x2000_2000, 0);
}

test "stamps are retired cycles turned into virtual ns at the time base's rate" {
    var trace: rtos.rtos_trace.Trace = .{};
    var stream: stream_mod.Stream = .{};
    var time: rtos.rtos_publish.TimeBase = .{ .base_ns = 1000, .cycles = 500, .retired = 1500, .hz = 500_000_000 };
    const publisher: Publisher = .{ .trace = &trace, .stream = &stream, .time = &time };
    try std.testing.expectEqual(@as(u64, 1400), publisher.nsOf(1200));
    try std.testing.expectEqual(@as(u64, 1000), publisher.nsOf(900));
    const raw: Publisher = .{ .trace = &trace, .stream = &stream };
    try std.testing.expectEqual(@as(u64, 1200), raw.nsOf(1200));
}
