//! Covers src/session/board_boundary.zig with src/session/zig_boundary.zig: a
//! debugger run on a real Board moves board time by exactly what retired
//! and reaches the pacer, before and after a mid-run speed change
//! (RA8EMU-709).
const std = @import("std");
const ra8 = @import("ra8");
const bus = ra8.chip.core.cpu.bus;
const Cpu = ra8.chip.core.cpu.cpu.Cpu;
const Board = ra8.board.board.Board;
const Machine = ra8.session.stop_machine.Machine;
const zig_boundary = ra8.session.step_hook.zig_boundary;
const board_boundary = ra8.session.board_boundary;
const pacing = ra8.board.run.pacing;

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

/// A wall clock that moves only when the pacer sleeps on it.
const FakeWall = struct {
    at: u64 = 0,

    fn clock(self: *FakeWall) ra8.board.run.pacer.Clock {
        return .{ .ctx = self, .nowFn = now, .sleepFn = sleep };
    }

    fn now(ctx: *anyopaque) u64 {
        const self: *FakeWall = @ptrCast(@alignCast(ctx));
        return self.at;
    }

    fn sleep(ctx: *anyopaque, ns: u64) void {
        const self: *FakeWall = @ptrCast(@alignCast(ctx));
        self.at += ns;
    }
};

test "a debugger run moves board time by what retired and paces it, across a speed change" {
    var store = try ra8.chip.core.cpu.memory.store.Store.init(null);
    defer store.deinit();
    const memory: ra8.chip.core.cpu.memory.guest.Guest = .{ .store = &store };
    var unit = Board.init(std.testing.allocator);
    defer unit.deinit();
    try ra8.board.wiring.attachBlocks(&unit, memory);
    // One instruction is a microsecond, so a chunk of 1000 is a millisecond.
    unit.time.base.setRate(1_000_000);
    var wall = FakeWall{};
    unit.run.pacing = pacing.Pacing.start(wall.clock(), unit.time.base.now(), 250);

    var code = ram();
    var cpu: Cpu = .{ .bus = code.view() };
    try cpu.reset(0);
    var machine = Machine{};
    machine.begin();
    var edge: board_boundary.BoardBoundary = .{ .board = &unit, .core = memory };
    var hook = edge.hook();
    hook.chunk = 1000;

    try std.testing.expect(try zig_boundary.run(.{ .cpu = &cpu }, &machine, 8000, null, null, hook) == .count);
    try std.testing.expectEqual(cpu.retired, unit.time.base.retired);
    try std.testing.expectEqual(@as(u64, 8 * std.time.ns_per_ms), unit.time.base.now());
    // 8 ms of board time at a quarter speed holds the wall to 32 ms.
    try std.testing.expectEqual(@as(u64, 32 * std.time.ns_per_ms), wall.at);

    const before = unit.time.base.now();
    unit.run.pacing.?.setSpeed(before, 5000);
    try std.testing.expectEqual(before, unit.time.base.now());
    try std.testing.expect(try zig_boundary.run(.{ .cpu = &cpu }, &machine, 10_000, null, null, hook) == .count);
    try std.testing.expectEqual(cpu.retired, unit.time.base.retired);
    try std.testing.expectEqual(@as(u64, 18 * std.time.ns_per_ms), unit.time.base.now());
    // 10 more ms at five times speed is 2 ms more wall.
    try std.testing.expectEqual(@as(u64, 34 * std.time.ns_per_ms), wall.at);
}
