//! RA8EMU-654 through the serve handler on a real board: `advance` runs
//! board time forward by a duration, exactly, and stops early on a break.
//! It also carries RA8EMU-767's end-to-end check: the RA8EMU-655 sleeper
//! (idler.zig with SysTick reloaded to one ten-minute period at 25 kHz)
//! sleeps ten virtual minutes through a session in under a host second.
const std = @import("std");
const ra8 = @import("ra8");
const idler = @import("../cli/idler.zig");
const store_board = @import("../cli/store_board.zig");

const memmap = ra8.chip.core.memmap;
const Cpu = ra8.chip.core.cpu.cpu.Cpu;
const GuestBus = ra8.chip.core.cpu.memory.guest_bus.GuestBus;
const NvicSource = ra8.chip.core.cpu.exception.nvic_source.NvicSource;
const Machine = ra8.session.stop_machine.Machine;
const api = ra8.session.session_api;
const BoardBoundary = ra8.session.board_boundary.BoardBoundary;
const server = ra8.rpc.session_server;
const advance = ra8.rpc.session_advance;
const proto = ra8.rpc.session_rpc;

const hz: u64 = 25_000;
const period: u64 = 600 * hz;
const ns_per_s: u64 = std.time.ns_per_s;

/// The sleeper served as `serve` serves an image: a session on the Zig
/// core with the board's boundary, and the RPC context over it.
const Rig = struct {
    store: store_board.Store = undefined,
    guest: store_board.Guest = undefined,
    board: ra8.board.board.Board = undefined,
    memory: GuestBus = undefined,
    pending: NvicSource = .{},
    cpu: Cpu = undefined,
    machine: Machine = .{},
    edge: BoardBoundary = undefined,
    session: api.Session = undefined,
    scratch: [64]u8 = undefined,
    context: server.Context = undefined,

    fn open(self: *Rig) !void {
        self.store = try store_board.Store.init(null);
        errdefer self.store.deinit();
        self.guest = .{ .store = &self.store };
        try idler.load(self.guest);
        try self.guest.writeWord(memmap.syst.rvr, @intCast(period - 1));
        self.board = ra8.board.board.Board.init(std.testing.allocator);
        errdefer self.board.deinit();
        try store_board.attach(&self.board, self.guest);
        self.board.time.base.setRate(hz);
        self.memory = GuestBus.of(&self.guest, false);
        self.cpu = .{ .bus = self.memory.view(), .source = self.pending.source() };
        self.pending.banked = &self.cpu.banked;
        try self.cpu.reset(idler.base);
        self.edge = .{ .board = &self.board, .core = self.guest };
        self.session = .{ .live = .{ .core = .{ .cpu = &self.cpu }, .machine = &self.machine, .budget = 1000, .boundary = self.edge.hook() } };
        self.session.attachTimeBase(&self.board.time.base);
        self.context = .{ .session = &self.session, .scratch = &self.scratch };
    }

    fn close(self: *Rig) void {
        self.board.deinit();
        self.store.deinit();
    }

    fn advanceBy(self: *Rig, ns: u64) !proto.Advanced {
        return switch (advance.advance(&self.context, .{ .core = .cpu0, .ns = ns })) {
            .ok => |moved| moved,
            .err => error.Refused,
        };
    }

    fn wakes(self: *Rig) !u32 {
        return self.guest.readWord(idler.counter_at);
    }
};

// The first wake lands at the start (idler.zig arms SysTick with CVR at
// zero), so the second is due ten virtual minutes later.
test "advance sleeps ten virtual minutes, wakes on time, in under a host second" {
    var rig: Rig = .{};
    try rig.open();
    defer rig.close();
    const first = try rig.advanceBy(ns_per_s);
    try std.testing.expectEqual(@as(u64, 0), first.from_ns);
    try std.testing.expectEqual(ns_per_s, first.to_ns);
    try std.testing.expectEqual(proto.StopReason.count, first.reason);
    const baseline = try rig.wakes();

    const started = std.Io.Timestamp.now(std.testing.io, .awake);
    const short = try rig.advanceBy(598 * ns_per_s);
    try std.testing.expect(started.durationTo(std.Io.Timestamp.now(std.testing.io, .awake)).toNanoseconds() < ns_per_s);
    try std.testing.expectEqual(599 * ns_per_s, short.to_ns);
    try std.testing.expectEqual(baseline, try rig.wakes());

    const over = try rig.advanceBy(2 * ns_per_s);
    try std.testing.expectEqual(601 * ns_per_s, over.to_ns);
    try std.testing.expectEqual(baseline + 1, try rig.wakes());
    try std.testing.expectEqual(@as(u64, 1000), rig.session.live.budget);
}

test "a breakpoint ends an advance early, at the time it reached" {
    var rig: Rig = .{};
    try rig.open();
    defer rig.close();
    _ = try rig.advanceBy(ns_per_s);
    _ = try rig.machine.addBreak(.{ .address = idler.handler_at });
    const moved = try rig.advanceBy(600 * ns_per_s);
    try std.testing.expectEqual(proto.StopReason.breakpoint, moved.reason);
    try std.testing.expectEqual(idler.handler_at, moved.address);
    try std.testing.expect(moved.to_ns < moved.from_ns + 600 * ns_per_s);
    try std.testing.expect(rig.context.pending != null);
}

test "a zero duration is refused as bad arguments" {
    var rig: Rig = .{};
    try rig.open();
    defer rig.close();
    const outcome = advance.advance(&rig.context, .{ .core = .cpu0, .ns = 0 });
    try std.testing.expect(outcome == .err);
}
