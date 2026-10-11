//! Covers the debugger run's sleep reach (RA8EMU-767): src/session/zig/boundary.zig
//! widens a chunk while the core sleeps with nothing to wake it, and
//! src/session/board/boundary.zig names how far, to the board's next edge.
const std = @import("std");
const ra8 = @import("ra8");
const idler = @import("../interfaces/cli/idler.zig");
const store_board = @import("../interfaces/cli/store_board.zig");

const memmap = ra8.chip.core.memmap;
const Cpu = ra8.chip.core.cpu.cpu.Cpu;
const GuestBus = ra8.chip.core.cpu.memory.guest.bus.GuestBus;
const NvicSource = ra8.chip.core.cpu.exception.nvic_source.NvicSource;
const Machine = ra8.session.stop_machine.Machine;
const zig_boundary = ra8.session.step_hook.zig.boundary;
const BoardBoundary = ra8.session.board.boundary.BoardBoundary;

/// Counts the boundaries a run passes and the instructions they carry.
const Counter = struct {
    ticks: u32 = 0,
    total: u64 = 0,

    fn tick(context: *anyopaque, instructions: u32) anyerror!void {
        const self: *Counter = @ptrCast(@alignCast(context));
        self.ticks += 1;
        self.total += instructions;
    }

    fn reach(context: *anyopaque, normal: u32) u32 {
        _ = context;
        return normal * 10;
    }
};

/// A core in `wfi; b .-2` over its own store, with an NVIC that has nothing pending.
const Sleeper = struct {
    store: store_board.Store = undefined,
    guest: store_board.Guest = undefined,
    memory: GuestBus = undefined,
    pending: NvicSource = .{},
    cpu: Cpu = undefined,

    fn open(self: *Sleeper) !void {
        self.store = try store_board.Store.init(null);
        errdefer self.store.deinit();
        self.guest = .{ .store = &self.store };
        self.memory = GuestBus.of(&self.guest, false);
        const view = self.memory.view();
        try view.writeWord(memmap.sram_base, memmap.sram_base + 0x1F00);
        try view.writeWord(memmap.sram_base + 4, (memmap.sram_base + 0x40) | 1);
        try view.writeWord(memmap.sram_base + 0x40, 0xE7FD_BF30);
        self.cpu = .{ .bus = view, .source = self.pending.source() };
        self.pending.banked = &self.cpu.banked;
        try self.cpu.reset(memmap.sram_base);
    }

    fn close(self: *Sleeper) void {
        self.store.deinit();
    }
};

fn sleepRun(reaching: bool, armed: bool) !Counter {
    var sleeper: Sleeper = .{};
    try sleeper.open();
    defer sleeper.close();
    var machine = Machine{};
    machine.begin();
    if (armed) _ = try machine.addBreak(.{ .address = memmap.sram_base + 0x7F0 });
    var counter: Counter = .{};
    const hook: zig_boundary.Boundary = .{ .context = &counter, .tickFn = Counter.tick, .chunk = 100, .sleepFn = if (reaching) Counter.reach else null };
    try std.testing.expect(try zig_boundary.run(.{ .cpu = &sleeper.cpu }, &machine, 50_000, null, null, hook) == .count);
    return counter;
}

test "a sleeping core's chunks reach as far as the boundary allows, and time still adds up" {
    const plain = try sleepRun(false, false);
    const reached = try sleepRun(true, false);
    try std.testing.expectEqual(@as(u64, 50_000), plain.total);
    try std.testing.expectEqual(@as(u64, 50_000), reached.total);
    try std.testing.expectEqual(@as(u32, 500), plain.ticks);
    try std.testing.expect(reached.ticks <= 51);
}

test "a breakpoint armed keeps every chunk at its normal width" {
    const armed = try sleepRun(true, true);
    try std.testing.expectEqual(@as(u64, 50_000), armed.total);
    try std.testing.expectEqual(@as(u32, 500), armed.ticks);
}

/// The idler image on a real board: SysTick armed one period ahead.
const Idle = struct {
    store: store_board.Store = undefined,
    board: ra8.board.board.Board = undefined,

    fn open(self: *Idle) !store_board.Guest {
        self.store = try store_board.Store.init(null);
        errdefer self.store.deinit();
        const core: store_board.Guest = .{ .store = &self.store };
        try idler.load(core);
        self.board = ra8.board.board.Board.init(std.testing.allocator);
        errdefer self.board.deinit();
        try store_board.attach(&self.board, core);
        return core;
    }

    fn close(self: *Idle) void {
        self.board.deinit();
        self.store.deinit();
    }
};

test "the board reaches a sleeping CPU0 to its next SysTick wrap in whole chunks" {
    var idle: Idle = .{};
    const core = try idle.open();
    defer idle.close();
    var edge: BoardBoundary = .{ .board = &idle.board, .core = core };
    const hook = edge.hook();
    const width = hook.sleepFn.?(hook.context, idler.chunk);
    try std.testing.expect(width > idler.chunk);
    try std.testing.expect(width <= idler.period);
    try std.testing.expectEqual(@as(u32, 0), width % idler.chunk);
}

test "CPU1 selected keeps the normal width" {
    var idle: Idle = .{};
    const core = try idle.open();
    defer idle.close();
    const cpu1: u8 = @backingInt(ra8.chip.periph.registry.Issuer.cpu1);
    var edge: BoardBoundary = .{ .board = &idle.board, .core = core, .selected = &cpu1 };
    const hook = edge.hook();
    try std.testing.expectEqual(idler.chunk, hook.sleepFn.?(hook.context, idler.chunk));
}
