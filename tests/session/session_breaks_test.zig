//! RA8EMU-765: each core's breakpoints read back through the session, apart
//! and in the order they were set.

const std = @import("std");
const ra8 = @import("ra8");
const bus = ra8.chip.core.cpu.bus;
const Cpu = ra8.chip.core.cpu.cpu.Cpu;
const api = ra8.session.api;
const session_breaks = ra8.session.session_breaks;
const Machine = ra8.session.stop_machine.Machine;
const zig_session = ra8.session.step_hook.zig_session;

/// A RAM image with a vector table and a few Thumb nops.
const Ram = struct {
    bytes: [256]u8 = @splat(0),

    fn init() Ram {
        var memory: Ram = .{};
        const code = [_]u8{ 0x40, 0, 0, 0, 0x09, 0, 0, 0, 0x00, 0xBF, 0x00, 0xBF, 0x00, 0xBF };
        @memcpy(memory.bytes[0..code.len], &code);
        return memory;
    }

    fn view(self: *Ram) bus.Bus {
        return .{ .ctx = self, .vtable = &.{ .read = read, .write = write } };
    }

    fn read(ctx: *anyopaque, address: u32, into: []u8) bus.Error!void {
        const self: *Ram = @ptrCast(@alignCast(ctx));
        if (address + into.len > self.bytes.len) return error.Unmapped;
        @memcpy(into, self.bytes[address..][0..into.len]);
    }

    fn write(ctx: *anyopaque, address: u32, bytes: []const u8) bus.Error!void {
        const self: *Ram = @ptrCast(@alignCast(ctx));
        if (address + bytes.len > self.bytes.len) return error.Unmapped;
        @memcpy(self.bytes[address..][0..bytes.len], bytes);
    }
};

const Pair = struct {
    memory: [2]Ram = .{ Ram.init(), Ram.init() },
    cpus: [2]Cpu = undefined,
    machines: [2]Machine = .{ .{}, .{} },
    session: api.Session = undefined,

    fn open(self: *Pair) !void {
        for (&self.cpus, &self.memory) |*cpu, *memory| {
            cpu.* = .{ .bus = memory.view() };
            try cpu.reset(0);
        }
        var live: zig_session.ZigSession = .{ .core = .{ .cpu = &self.cpus[0] }, .machine = &self.machines[0], .budget = 10 };
        live.other = .{ .core = .{ .cpu = &self.cpus[1] }, .machine = &self.machines[1], .budget = 10, .index = 1 };
        self.session = .{ .live = live };
    }
};

test "each core's breaks come back apart, in the order they were set" {
    var pair: Pair = .{};
    try pair.open();
    const session = &pair.session;
    _ = try session.setBreakpoint(.cpu0, .{ .address = 0x0C });
    _ = try session.setBreakpoint(.cpu1, .{ .address = 0x0A });
    _ = try session.setBreakpoint(.cpu0, .{ .address = 0x08 });
    _ = try session.setBreakpoint(.cpu1, .{ .address = 0x0C });
    _ = try session.setBreakpoint(.cpu0, .{ .address = 0x0A });

    var into: [8]session_breaks.Entry = undefined;
    const cpu0 = try session_breaks.list(session, .cpu0, &into);
    try std.testing.expectEqual(@as(usize, 3), cpu0.len);
    try std.testing.expectEqual(@as(u32, 0x0C), cpu0[0].address);
    try std.testing.expectEqual(@as(u32, 0x08), cpu0[1].address);
    try std.testing.expectEqual(@as(u32, 0x0A), cpu0[2].address);
    for (cpu0) |entry| try std.testing.expect(entry.enabled);

    const cpu1 = try session_breaks.list(session, .cpu1, &into);
    try std.testing.expectEqual(@as(usize, 2), cpu1.len);
    try std.testing.expectEqual(@as(u32, 0x0A), cpu1[0].address);
    try std.testing.expectEqual(@as(u32, 0x0C), cpu1[1].address);
}

test "a cleared break leaves the list and the order of the rest holds" {
    var pair: Pair = .{};
    try pair.open();
    const session = &pair.session;
    _ = try session.setBreakpoint(.cpu1, .{ .address = 0x08 });
    const middle = try session.setBreakpoint(.cpu1, .{ .address = 0x0A });
    _ = try session.setBreakpoint(.cpu1, .{ .address = 0x0C });
    try session.clearBreakpoint(.cpu1, middle);

    var into: [8]session_breaks.Entry = undefined;
    const cpu1 = try session_breaks.list(session, .cpu1, &into);
    try std.testing.expectEqual(@as(usize, 2), cpu1.len);
    try std.testing.expectEqual(@as(u32, 0x08), cpu1[0].address);
    try std.testing.expectEqual(@as(u32, 0x0C), cpu1[1].address);
    try std.testing.expectEqual(@as(usize, 0), (try session_breaks.list(session, .cpu0, &into)).len);
}

test "the gutter addresses skip disabled breaks and fit the pane's breaks slice" {
    var pair: Pair = .{};
    try pair.open();
    const session = &pair.session;
    _ = try session.setBreakpoint(.cpu0, .{ .address = 0x08 });
    const off = try session.setBreakpoint(.cpu0, .{ .address = 0x0A });
    _ = try session.setBreakpoint(.cpu0, .{ .address = 0x0C });
    const machine = try session.machine(.cpu0);
    try machine.breaks.setEnabled(off, false);

    var entries: [8]session_breaks.Entry = undefined;
    const listed = try session_breaks.list(session, .cpu0, &entries);
    try std.testing.expect(!listed[1].enabled);

    var into: [8]u32 = undefined;
    const breaks: []const u32 = try session_breaks.addresses(session, .cpu0, &into);
    try std.testing.expectEqualSlices(u32, &.{ 0x08, 0x0C }, breaks);

    var short: [1]u32 = undefined;
    try std.testing.expectEqualSlices(u32, &.{0x08}, try session_breaks.addresses(session, .cpu0, &short));
}
