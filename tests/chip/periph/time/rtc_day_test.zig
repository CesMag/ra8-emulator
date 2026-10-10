//! RA8EMU-182's last done condition: a run at 100x for a virtual day shows
//! the RTC exactly one day later. The idle soak image (soaker.zig, clean)
//! runs with the RTC started at --rtc-start's virtual gear, paced at 100x
//! against a fake wall clock, at a 1 MHz core clock so a day is 8.64e10
//! cycles, with idle fast-forward on.
const std = @import("std");
const ra8 = @import("ra8");
const cli_app = @import("cli_app");
const soaker = @import("../../../interfaces/cli/soaker.zig");
const store_board = @import("../../../interfaces/cli/store_board.zig");

const zig_run = cli_app.zig_run;
const cpu_boot = ra8.chip.core.cpu.boot;
const pacing = ra8.board.run.pacing;
const pacer = ra8.board.run.pacer;
const Calendar = ra8.chip.periph.rtc_clock.Calendar;

const hz: u64 = 1_000_000;
const day_s: u64 = 24 * 3600;
const hundred_x: u64 = 100_000;

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

const Day = struct { date: Calendar, virtual_ns: u64, wall_ns: u64 };

fn runDay(start: Calendar) !Day {
    var store = try store_board.Store.init(null);
    defer store.deinit();
    const core: store_board.Guest = .{ .store = &store };
    try soaker.load(core, false);
    var board = ra8.board.board.Board.init(std.testing.allocator);
    defer board.deinit();
    try store_board.attach(&board, core);
    board.time.base.setRate(hz);
    board.clock.seed(start);
    var wall: FakeWall = .{};
    board.run.pacing = pacing.Pacing.start(wall.clock(), board.time.base.now(), hundred_x);
    var timebase: ra8.chip.periph.clocks.Clocks = .{ .per_chunk = 5_000 };
    var clock: zig_run.Clock = .{ .io = std.testing.io, .memory = core, .board = &board, .timebase = &timebase, .idle_skip = true };
    var ran: u64 = 0;
    var output: [1024]u8 = undefined;
    var stream: std.Io.Writer = .fixed(&output);
    _ = try cpu_boot.start(&stream, .zig, core, &board.bus, soaker.base, day_s * hz, &ran, .{ .boundary = clock.boundary() });
    return .{ .date = board.clock.now, .virtual_ns = board.time.base.now(), .wall_ns = wall.ns };
}

test "a virtual day at 100x moves the RTC on exactly one day" {
    const day = try runDay(.{ .year = 26, .month = 1, .day = 1 });
    try std.testing.expectEqual(day_s * 1_000_000_000, day.virtual_ns);
    try std.testing.expectEqual(Calendar{ .year = 26, .month = 1, .day = 2 }, day.date);
    // 100x: a virtual day is 864 wall seconds, give or take the last pace.
    try std.testing.expect(day.wall_ns >= 863 * 1_000_000_000);
    try std.testing.expect(day.wall_ns <= 865 * 1_000_000_000);
}

test "a virtual day at 100x across Feb 28 in a leap year lands on Feb 29" {
    const day = try runDay(.{ .hour = 6, .minute = 30, .day = 28, .month = 2, .year = 28 });
    try std.testing.expectEqual(Calendar{ .hour = 6, .minute = 30, .day = 29, .month = 2, .year = 28 }, day.date);
}
