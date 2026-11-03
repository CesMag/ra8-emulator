const std = @import("std");
const ra8 = @import("ra8");
const Sink = @import("../../session/history/commit_sink.zig").Sink;
const gpa = std.testing.allocator;
const server = ra8.rpc.session.server;

const Clock = struct {
    ns: u64 = 0,
    reads: usize = 0,
    fn now(context: *anyopaque) u64 {
        const self: *Clock = @ptrCast(@alignCast(context));
        self.reads += 1;
        return self.ns;
    }
};

const Output = struct {
    completions: usize = 0,

    pub fn emit(self: *Output, comptime T: type, _: u16, value: anytype, _: []u8) !void {
        if (T == ra8.rpc.session.rpc.TransportEvent) {
            if (value.finished != 0) self.completions += 1;
        } else return error.UnexpectedEvent;
    }
};

fn stage(rec: *ra8.session.history_recorder.Recorder) !void {
    try rec.recordBoundary(.{ .position = .{}, .seq = 0 }, .{ .what = .c6_bytes, .body = "pending" });
}

test "orderly served flush reports failure and permits a complete retry" {
    var sink: Sink = .{};
    defer sink.bytes.deinit(gpa);
    var rec = try ra8.session.history_recorder.Recorder.init(gpa, sink.storage(), .{});
    defer rec.deinit();
    var served: ra8.rpc.served_setup.Served = undefined;
    try served.open(gpa, std.testing.io, "tests/fixtures/gpio/blink.elf", null, null);
    defer served.deinit();
    served.owner.session().persistent_recorder = &rec;
    defer served.owner.session().persistent_recorder = null;
    try stage(&rec);
    const pending = rec.pendingBytes();
    sink.fail_flush = true;
    try std.testing.expectError(error.FlushFailed, served.flushHistory());
    try std.testing.expectEqual(pending, rec.pendingBytes());
    try std.testing.expectEqual(@as(usize, 0), sink.bytes.items.len);
    try served.flushHistory();
    try std.testing.expectEqual(pending, sink.bytes.items.len);
    try std.testing.expectEqual(@as(usize, 0), rec.pendingBytes());
}

test "idle transport pumping honors the caller deadline without guest progress" {
    var sink: Sink = .{};
    defer sink.bytes.deinit(gpa);
    var rec = try ra8.session.history_recorder.Recorder.init(gpa, sink.storage(), .{});
    defer rec.deinit();
    var served: ra8.rpc.served_setup.Served = undefined;
    try served.open(gpa, std.testing.io, "tests/fixtures/gpio/blink.elf", null, null);
    defer served.deinit();
    served.owner.session().persistent_recorder = &rec;
    defer served.owner.session().persistent_recorder = null;
    var clock: Clock = .{};
    rec.bindClock(.{ .context = &clock, .nowFn = Clock.now });
    var transport_clock: Clock = .{ .ns = 50 * std.time.ns_per_s };
    served.context.wall = .{ .context = &transport_clock, .nowFn = Clock.now };
    try stage(&rec);
    const before = served.owner.session().currentPosition();
    var output: Output = .{};
    var tx: [256]u8 = undefined;
    clock.ns = 249_999_999;
    try server.pumpTransport(&served.context, &output, &tx);
    try std.testing.expectEqual(@as(usize, 0), sink.flushes);
    clock.ns = 250_000_000;
    try server.pumpTransport(&served.context, &output, &tx);
    try std.testing.expectEqual(@as(usize, 1), sink.flushes);
    try std.testing.expectEqual(@as(usize, 0), transport_clock.reads);
    try std.testing.expectEqualDeep(before, served.owner.session().currentPosition());
}

test "idle nonrecording transport pumping does not sample its wall clock" {
    var served: ra8.rpc.served_setup.Served = undefined;
    try served.open(gpa, std.testing.io, "tests/fixtures/gpio/blink.elf", null, null);
    defer served.deinit();
    var clock: Clock = .{};
    served.context.wall = .{ .context = &clock, .nowFn = Clock.now };
    var output: Output = .{};
    var tx: [256]u8 = undefined;
    try server.pumpTransport(&served.context, &output, &tx);
    try std.testing.expectEqual(@as(usize, 0), clock.reads);
}

test "async advance retries a failed final flush and delivers completion once" {
    var sink: Sink = .{};
    defer sink.bytes.deinit(gpa);
    var rec = try ra8.session.history_recorder.Recorder.init(gpa, sink.storage(), .{});
    defer rec.deinit();
    var served: ra8.rpc.served_setup.Served = undefined;
    try served.open(gpa, std.testing.io, "tests/fixtures/gpio/blink.elf", null, null);
    defer served.deinit();
    served.owner.session().persistent_recorder = &rec;
    defer served.owner.session().persistent_recorder = null;
    var clock: Clock = .{};
    rec.bindClock(.{ .context = &clock, .nowFn = Clock.now });
    served.context.wall = .{ .context = &clock, .nowFn = Clock.now };
    const plane = served.context.transport.?;
    const subscribed = ra8.rpc.session.handlers.subscribe(&served.context, .{ .core = .cpu0, .topic = .transport });
    try std.testing.expect(subscribed == .ok);
    served.context.advance_from_ns = try served.owner.session().now();
    served.context.advance_target_ns = served.context.advance_from_ns + 10;
    const ticket = try plane.command(.{ .advance = .{ .core = .cpu0, .ns = 10 } });
    served.context.advance_ticket = ticket;
    try stage(&rec);
    sink.fail_flush = true;
    var output: Output = .{};
    var tx: [256]u8 = undefined;
    try std.testing.expectError(error.FlushFailed, server.pumpTransport(&served.context, &output, &tx));
    try std.testing.expectEqual(ticket, served.context.advance_ticket.?);
    try std.testing.expect(plane.pending_finish != null);
    try std.testing.expectEqual(@as(usize, 0), output.completions);
    try server.pumpTransport(&served.context, &output, &tx);
    try std.testing.expect(served.context.advance_ticket == null);
    try std.testing.expect(plane.pending_finish == null);
    try std.testing.expectEqual(@as(usize, 0), rec.pendingBytes());
    try std.testing.expectEqual(@as(usize, 1), output.completions);
    const flushes = sink.flushes;
    try server.pumpTransport(&served.context, &output, &tx);
    try std.testing.expectEqual(flushes, sink.flushes);
    try std.testing.expectEqual(@as(usize, 1), output.completions);
}
