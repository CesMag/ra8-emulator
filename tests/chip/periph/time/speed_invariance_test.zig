//! RA8EMU-183: speed changes wall time, never behaviour. The built-in idle
//! image runs on the Zig core at 0.1x, 1x, 5x and max, paced against a fake
//! wall clock whose sleeps advance it at once, and every SysTick handler
//! entry must land on the same instruction and the same virtual cycle.
const std = @import("std");
const ra8 = @import("ra8");
const cli_app = @import("cli_app");
const store_board = @import("../../../interfaces/cli/store_board.zig");
const idler = @import("../../../interfaces/cli/idler.zig");

const zig_run = cli_app.zig_run;
const cpu_boot = ra8.chip.core.cpu.boot;
const pacing = ra8.board.run.pacing;
const pacer = ra8.board.run.pacer;
const budget: u64 = 2_000_000;
const most_entries = 16;

/// A wall clock that only moves when the pacer sleeps on it.
const FakeWall = struct {
    ns: u64 = 0,

    fn clock(self: *FakeWall) pacer.Clock {
        return .{ .ctx = self, .nowFn = now, .sleepFn = sleep };
    }

    fn now(ctx: *anyopaque) u64 {
        const self: *FakeWall = @ptrCast(@alignCast(ctx));
        return self.ns;
    }

    fn sleep(ctx: *anyopaque, ns: u64) void {
        const self: *FakeWall = @ptrCast(@alignCast(ctx));
        self.ns += ns;
    }
};

/// Each SysTick handler entry as (instructions retired, virtual cycles).
const Timeline = struct {
    timebase: *const ra8.chip.periph.clocks.Clocks,
    retired: u64 = 0,
    entries: [most_entries][2]u64 = undefined,
    len: usize = 0,

    fn retire(context: *anyopaque, address: u32) void {
        const self: *Timeline = @ptrCast(@alignCast(context));
        self.retired += 1;
        if (address != idler.handler_at or self.len == most_entries) return;
        self.entries[self.len] = .{ self.retired, self.timebase.elapsed };
        self.len += 1;
    }
};

const Run = struct { timeline: Timeline, wall_ns: u64 };

fn runAt(speed_milli: ?u64) !Run {
    var store = try store_board.Store.init(null);
    defer store.deinit();
    const core: store_board.Guest = .{ .store = &store };
    try idler.load(core);
    var board = ra8.board.board.Board.init(std.testing.allocator);
    defer board.deinit();
    try store_board.attach(&board, core);
    var wall: FakeWall = .{};
    if (speed_milli) |factor| board.run.pacing = pacing.Pacing.start(wall.clock(), board.time.base.now(), factor);
    var timebase: ra8.chip.periph.clocks.Clocks = .{ .per_chunk = idler.chunk };
    var clock: zig_run.Clock = .{ .io = std.testing.io, .memory = core, .board = &board, .timebase = &timebase };
    var timeline: Timeline = .{ .timebase = &timebase };
    const listener: ra8.chip.core.cpu.cpu.RetireListener = .{ .context = &timeline, .instructionFn = Timeline.retire };
    var ran: u64 = 0;
    var output: [1024]u8 = undefined;
    var stream: std.Io.Writer = .fixed(&output);
    _ = try cpu_boot.start(&stream, .zig, core, &board.bus, idler.base, budget, &ran, .{ .boundary = clock.boundary(), .retire_listener = listener });
    return .{ .timeline = timeline, .wall_ns = wall.ns };
}

test "every SysTick entry lands on the same instruction and cycle at every speed" {
    const reference = try runAt(null);
    try std.testing.expect(reference.timeline.len > 2);
    for ([_]u64{ 100, 1000, 5000 }) |factor| {
        const paced = try runAt(factor);
        try std.testing.expectEqual(reference.timeline.len, paced.timeline.len);
        for (reference.timeline.entries[0..reference.timeline.len], paced.timeline.entries[0..paced.timeline.len]) |want, got| {
            try std.testing.expectEqual(want, got);
        }
    }
}

test "the pacer really ran: a slower factor spends more wall time" {
    const tenth = try runAt(100);
    const real = try runAt(1000);
    const fast = try runAt(5000);
    try std.testing.expect(tenth.wall_ns > real.wall_ns);
    try std.testing.expect(real.wall_ns > fast.wall_ns);
}
