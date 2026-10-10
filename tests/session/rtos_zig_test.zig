//! Tests for src/session/rtos_zig.zig: the listener in front of a Zig-core
//! run's bus and exception source.
const std = @import("std");
const ra8 = @import("ra8");
const rtos_hook = ra8.session.step_hook.rtos_hook;
const rtos_trace = ra8.session.step_hook.rtos_trace;
const Listener = rtos_hook.zig.Listener;
const bus = ra8.chip.core.cpu.bus;
const Source = ra8.chip.core.cpu.exception.source.Source;
const Entry = ra8.chip.core.cpu.exception.active.Entry;

/// A bus that keeps the last write and reads zeros.
const Memory = struct {
    last: u32 = 0,
    fn view(self: *Memory) bus.Bus {
        return .{ .ctx = self, .vtable = &.{ .read = read, .write = write } };
    }
    fn read(_: *anyopaque, _: u32, into: []u8) bus.Error!void {
        @memset(into, 0);
    }
    fn write(ctx: *anyopaque, address: u32, _: []const u8) bus.Error!void {
        const self: *Memory = @ptrCast(@alignCast(ctx));
        self.last = address;
    }
};

/// A source that counts what it is told.
const Pending = struct {
    taken: u32 = 0,
    returned: u32 = 0,
    fn source(self: *Pending) Source {
        return .{ .ctx = self, .vtable = &.{ .winner = winner, .taken = onTaken, .returned = onReturned } };
    }
    fn winner(_: *anyopaque, _: bus.Bus) bus.Error!?Entry {
        return null;
    }
    fn onTaken(ctx: *anyopaque, _: bus.Bus, _: u9) bus.Error!void {
        const self: *Pending = @ptrCast(@alignCast(ctx));
        self.taken += 1;
    }
    fn onReturned(ctx: *anyopaque, _: bus.Bus, _: u9) bus.Error!void {
        const self: *Pending = @ptrCast(@alignCast(ctx));
        self.returned += 1;
    }
};

test "a word stored to the pointer through the bus is a switch, and still lands" {
    var tracer = rtos_hook.Tracer{ .address = 0x2200_1ABC };
    var listener = Listener{ .tracer = &tracer };
    var memory = Memory{};
    const seen = listener.onBus(memory.view());
    var word: [4]u8 = undefined;
    std.mem.writeInt(u32, &word, 0x2200_10F0, .little);
    try seen.write(0x2200_1ABC, &word);
    try seen.write(0x2200_1ABC, word[0..2]);
    try std.testing.expectEqual(@as(u32, 0x2200_1ABC), memory.last);
    try std.testing.expectEqual(@as(usize, 1), tracer.trace.list().len);
    try std.testing.expectEqual(@as(u32, 0x2200_10F0), tracer.trace.list()[0].thread);
}

test "exceptions taken and returned are recorded and passed on" {
    var ticks: u64 = 7;
    var tracer = rtos_hook.Tracer{ .address = 0x2200_1ABC, .now = &ticks };
    var listener = Listener{ .tracer = &tracer };
    var memory = Memory{};
    var pending = Pending{};
    const seen = listener.onSource(pending.source());
    try seen.taken(memory.view(), 14);
    try seen.returned(memory.view(), 14);
    try std.testing.expectEqual(@as(u32, 1), pending.taken);
    try std.testing.expectEqual(@as(u32, 1), pending.returned);
    const got = tracer.trace.list();
    try std.testing.expectEqual(rtos_trace.Kind.enter, got[0].kind);
    try std.testing.expectEqual(@as(u16, 14), got[0].exception);
    try std.testing.expectEqual(@as(u64, 7), got[0].when);
    try std.testing.expectEqual(rtos_trace.Kind.leave, got[1].kind);
}

test "the core's retired count is lent as the load clock" {
    var tracer = rtos_hook.Tracer{ .address = 0x2200_1ABC };
    var listener = Listener{ .tracer = &tracer };
    const wrap = listener.wrap();
    var retired: u64 = 41;
    wrap.retiredFn.?(wrap.context, &retired);
    try std.testing.expectEqual(@as(?*const u64, &retired), tracer.trace.fine);
    var word: [4]u8 = undefined;
    std.mem.writeInt(u32, &word, 0x2200_10F0, .little);
    var memory = Memory{};
    const seen = listener.onBus(memory.view());
    retired = 42;
    try seen.write(0x2200_1ABC, &word);
    try std.testing.expectEqual(@as(u64, 42), tracer.trace.loadNow(0));
}

test "the listener passes the core's fault latch through as a latch" {
    var tracer = rtos_hook.Tracer{ .address = 0x2200_1ABC };
    var listener = Listener{ .tracer = &tracer };
    var under = @import("latch_bus.zig").Latches{};
    try listener.onBus(under.view()).latch(0xE000_ED28, 1 << 25);
    try std.testing.expectEqual(@as(u32, 1 << 25), under.latched);
    try std.testing.expectEqual(@as(u32, 0), under.writes);
}
