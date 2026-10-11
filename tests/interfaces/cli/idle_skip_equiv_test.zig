//! RA8EMU-185's done condition: an idle-heavy image (idler.zig) reaches the
//! same state at the same virtual time with and without idle fast-forward.
const std = @import("std");
const ra8 = @import("ra8");
const cli_app = @import("cli_app");
const store_board = @import("store_board.zig");

const zig_run = cli_app.zig.run;
const cpu_boot = ra8.chip.core.cpu.boot;

const idler = @import("idler.zig");
const budget: u64 = 1_000_000;

/// What one run ended with.
const Ended = struct {
    status: u8,
    ran: u64,
    elapsed: u64,
    ticks: u64,
    count: u32,
    pc: u32,
    closes: u32,
};

/// The run's Clock with a count of the stretches it closed.
const Counted = struct {
    clock: *zig_run.Clock,
    closes: u32 = 0,

    fn boundary(self: *Counted, skip: bool) cpu_boot.Boundary {
        return .{ .context = self, .widthFn = width, .closeFn = close, .sleepFn = if (skip) asleep else null };
    }

    fn width(context: *anyopaque) u32 {
        const self: *Counted = @ptrCast(@alignCast(context));
        return self.clock.width();
    }

    fn asleep(context: *anyopaque, normal: u32) u32 {
        const self: *Counted = @ptrCast(@alignCast(context));
        return self.clock.asleepWidth(normal);
    }

    fn close(context: *anyopaque, instructions: u32) anyerror!void {
        const self: *Counted = @ptrCast(@alignCast(context));
        self.closes += 1;
        try self.clock.close(instructions);
    }
};

fn runIdler(skip: bool, reload: ?u32, cycles: u64) !Ended {
    var store = try store_board.Store.init(null);
    defer store.deinit();
    const core: store_board.Guest = .{ .store = &store };
    try idler.load(core);
    if (reload) |value| try core.writeWord(ra8.chip.core.memmap.syst.rvr, value);
    var board = ra8.board.board.Board.init(std.testing.allocator);
    defer board.deinit();
    try store_board.attach(&board, core);
    var timebase: ra8.chip.periph.clocks.Clocks = .{ .per_chunk = idler.chunk };
    var clock: zig_run.Clock = .{ .io = std.testing.io, .memory = core, .board = &board, .timebase = &timebase, .idle_skip = skip };
    var counted: Counted = .{ .clock = &clock };
    var ran: u64 = 0;
    var final: cpu_boot.Regs = .{};
    var output: [1024]u8 = undefined;
    var stream: std.Io.Writer = .fixed(&output);
    const status = try cpu_boot.start(&stream, .zig, core, &board.bus, idler.base, cycles, &ran, .{ .boundary = counted.boundary(skip), .final = &final });
    return .{
        .status = status,
        .ran = ran,
        .elapsed = timebase.elapsed,
        .ticks = timebase.ticks,
        .count = try core.readWord(idler.counter_at),
        .pc = final.pc,
        .closes = counted.closes,
    };
}

test "an idle image ends in the same state at the same virtual time with and without the skip" {
    const stepped = try runIdler(false, null, budget);
    const skipped = try runIdler(true, null, budget);
    try std.testing.expect(stepped.count > 0);
    try std.testing.expectEqual(stepped.status, skipped.status);
    try std.testing.expectEqual(stepped.ran, skipped.ran);
    try std.testing.expectEqual(stepped.elapsed, skipped.elapsed);
    try std.testing.expectEqual(stepped.ticks, skipped.ticks);
    try std.testing.expectEqual(stepped.count, skipped.count);
    try std.testing.expectEqual(stepped.pc, skipped.pc);
}

test "the skip closes fewer boundaries on an idle image" {
    const stepped = try runIdler(false, null, budget);
    const skipped = try runIdler(true, null, budget);
    try std.testing.expect(skipped.closes < stepped.closes);
}

test "with a period that is not a whole number of stretches, the skip delivers every wrap the stepped run does" {
    // 50 wraps of a 200,003-cycle period: each wake starts part way down the
    // counter, so a stretch sized by the full period would overshoot the next
    // wrap and in time swallow one (RA8EMU-618). From CVR = 0 the 50th wrap
    // lands on cycle 50 * 200,003 (RA8EMU-657), so a short tail lets its
    // handler run.
    const reload: u32 = 200_002;
    const stepped = try runIdler(false, reload, 50 * 200_003 + 100_000);
    const skipped = try runIdler(true, reload, 50 * 200_003 + 100_000);
    try std.testing.expectEqual(@as(u32, 50), stepped.count);
    try std.testing.expectEqual(stepped.ticks, skipped.ticks);
    try std.testing.expectEqual(stepped.count, skipped.count);
    try std.testing.expectEqual(stepped.elapsed, skipped.elapsed);
    try std.testing.expectEqual(stepped.pc, skipped.pc);
    try std.testing.expectEqual(@as(u32, @intCast(skipped.ticks)), skipped.count);
}
