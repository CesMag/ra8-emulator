//! Tests for src/session/zig/boundary.zig: the debugger's run passes the
//! board's boundary by what each chunk retired (RA8EMU-709).
const std = @import("std");
const ra8 = @import("ra8");
const bus = ra8.chip.core.cpu.bus;
const Cpu = ra8.chip.core.cpu.cpu.Cpu;
const zig_core = ra8.session.step_hook.zig.core;
const zig_boundary = ra8.session.step_hook.zig.boundary;
const zig_session = ra8.session.step_hook.zig.session;
const Machine = ra8.session.stop_machine.Machine;

/// 64 bytes of RAM at address 0, the vector table first.
const Ram = struct {
    bytes: [64]u8,

    fn view(self: *Ram) bus.Bus {
        return .{ .ctx = self, .vtable = &.{ .read = read, .write = write } };
    }

    fn read(ctx: *anyopaque, address: u32, into: []u8) bus.Error!void {
        const self: *Ram = @ptrCast(@alignCast(ctx));
        if (address + into.len > self.bytes.len) return bus.Error.Unmapped;
        @memcpy(into, self.bytes[address..][0..into.len]);
    }

    fn write(ctx: *anyopaque, address: u32, from: []const u8) bus.Error!void {
        const self: *Ram = @ptrCast(@alignCast(ctx));
        if (address + from.len > self.bytes.len) return bus.Error.Unmapped;
        @memcpy(self.bytes[address..][0..from.len], from);
    }
};

// sp 0x40, reset 0x09 ; 0x08 nop ; 0x0A nop ; 0x0C nop ; 0x0E b 0x08
fn ram() Ram {
    var r: Ram = .{ .bytes = @as([64]u8, @splat(0)) };
    const image = [_]u8{
        0x40, 0x00, 0x00, 0x00, 0x09, 0x00, 0x00, 0x00,
        0x00, 0xBF, 0x00, 0xBF, 0x00, 0xBF, 0xFB, 0xE7,
    };
    @memcpy(r.bytes[0..image.len], &image);
    return r;
}

/// Records every boundary it is passed.
const Ticks = struct {
    seen: [8]u32 = @splat(0),
    len: usize = 0,
    fail: bool = false,

    fn hook(self: *Ticks, chunk: u32) zig_boundary.Boundary {
        return .{ .context = self, .tickFn = tick, .chunk = chunk };
    }

    fn tick(context: *anyopaque, instructions: u32) anyerror!void {
        const self: *Ticks = @ptrCast(@alignCast(context));
        if (self.fail) return error.Refused;
        self.seen[self.len] = instructions;
        self.len += 1;
    }

    fn total(self: Ticks) u64 {
        var sum: u64 = 0;
        for (self.seen[0..self.len]) |one| sum += one;
        return sum;
    }
};

test "a run passes the boundary every chunk and once for the remainder" {
    var memory = ram();
    var cpu: Cpu = .{ .bus = memory.view() };
    try cpu.reset(0);
    const core: zig_core.ZigCore = .{ .cpu = &cpu };
    var machine = Machine{};
    machine.begin();
    var ticks: Ticks = .{};
    const ended = try zig_boundary.run(core, &machine, 2500, null, null, ticks.hook(1024));
    try std.testing.expect(ended == .count);
    try std.testing.expectEqualSlices(u32, &.{ 1024, 1024, 452 }, ticks.seen[0..ticks.len]);
    try std.testing.expectEqual(cpu.retired, ticks.total());
}

test "a stop mid chunk ticks only what ran before it" {
    var memory = ram();
    var cpu: Cpu = .{ .bus = memory.view() };
    try cpu.reset(0);
    const core: zig_core.ZigCore = .{ .cpu = &cpu };
    var machine = Machine{};
    _ = try machine.breaks.add(.{ .address = 0x0E });
    machine.begin();
    var ticks: Ticks = .{};
    const ended = try zig_boundary.run(core, &machine, 100, null, null, ticks.hook(16));
    try std.testing.expect(ended == .stop);
    try std.testing.expectEqualSlices(u32, &.{3}, ticks.seen[0..ticks.len]);
    try std.testing.expectEqual(cpu.retired, ticks.total());
}

test "a refused boundary ends the run as BoundaryFailed" {
    var memory = ram();
    var cpu: Cpu = .{ .bus = memory.view() };
    try cpu.reset(0);
    const core: zig_core.ZigCore = .{ .cpu = &cpu };
    var machine = Machine{};
    machine.begin();
    var ticks: Ticks = .{ .fail = true };
    try std.testing.expectError(zig_boundary.Error.BoundaryFailed, zig_boundary.run(core, &machine, 10, null, null, ticks.hook(4)));
}

test "the session's step passes the boundary for the one instruction" {
    var memory = ram();
    var cpu: Cpu = .{ .bus = memory.view() };
    try cpu.reset(0);
    var machine = Machine{};
    var ticks: Ticks = .{};
    var session: zig_session.ZigSession = .{ .core = .{ .cpu = &cpu }, .machine = &machine, .budget = 100, .boundary = ticks.hook(64) };
    try std.testing.expect((try session.go(.step)).stop == .stepped);
    try std.testing.expectEqualSlices(u32, &.{1}, ticks.seen[0..ticks.len]);
}
