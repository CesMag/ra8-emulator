//! RA8EMU-186's done condition: a soak catches a stack overflow at the
//! virtual hour it happens, and a clean image sleeps through a virtual week
//! with no events. Both run with idle fast-forward, at a 1 MHz core clock so
//! SysTick's longest period is 16.8 virtual seconds. The overflow happens
//! on the last wake, and the soak sees it at the boundary that ends the next
//! sleep: one period later, give or take the stretch it lands in
//! (RA8EMU-657).
const std = @import("std");
const ra8 = @import("ra8");
const cli_app = @import("cli_app");
const store_board = @import("store_board.zig");

const zig_run = cli_app.zig.run;
const cpu_boot = ra8.chip.core.cpu.boot;
const soak = ra8.session.run.soak;

const soaker = @import("soaker.zig");
const hz: u64 = 1_000_000;
const ns_per_hour: u64 = 3600 * 1_000_000_000;
const week_cycles: u64 = 7 * 24 * 3600 * hz;

/// What one soak ended with.
const Ended = struct {
    event: ?soak.Event,
    now_ns: u64,
    count: u32,
    ticks: u64,
    collapsed: u64,
};

fn runSoak(overflow: bool) !Ended {
    var store = try store_board.Store.init(null);
    defer store.deinit();
    const core: store_board.Guest = .{ .store = &store };
    try soaker.load(core, overflow);
    var board = ra8.board.board.Board.init(std.testing.allocator);
    defer board.deinit();
    try store_board.attach(&board, core);
    board.time.base.setRate(hz);
    var asked: ra8.session.run.policy.RunPolicy = .{};
    asked.soak.armed = true;
    asked.attach(&board);
    var timebase: ra8.chip.periph.clocks.Clocks = .{ .per_chunk = 5_000 };
    var clock: zig_run.Clock = .{ .io = std.testing.io, .memory = core, .board = &board, .timebase = &timebase, .policy = &asked, .idle_skip = true };
    var ran: u64 = 0;
    var final: cpu_boot.Regs = .{};
    var output: [1024]u8 = undefined;
    var stream: std.Io.Writer = .fixed(&output);
    _ = try cpu_boot.start(&stream, .zig, core, &board.bus, soaker.base, week_cycles, &ran, .{ .boundary = clock.boundary(), .final = &final });
    clock.soakFaults();
    return .{ .event = asked.soak.event, .now_ns = board.time.base.now(), .count = try core.readWord(soaker.counter_at), .ticks = timebase.ticks, .collapsed = timebase.collapsed };
}

test "a soak catches a stack overflow in the virtual hour it happens" {
    const ended = try runSoak(true);
    const event = ended.event orelse return error.NoEvent;
    try std.testing.expectEqual(soak.Kind.stack_overflow, event.kind);
    try std.testing.expectEqual(@as(u32, soaker.wakes), ended.count);
    const due_ns = soaker.wakes * soaker.period * (1_000_000_000 / hz);
    try std.testing.expect(event.at_ns >= due_ns);
    try std.testing.expect(event.at_ns - due_ns < soaker.period * (1_000_000_000 / hz) + 1_000_000_000);
    try std.testing.expectEqual(@as(u64, 1), event.at_ns / ns_per_hour);
}

test "a clean image sleeps through a virtual week with no events" {
    const ended = try runSoak(false);
    try std.testing.expect(ended.event == null);
    try std.testing.expect(ended.now_ns >= 7 * 24 * ns_per_hour);
    // Every wrap of the week reached the handler: none collapsed into a
    // widened stretch (RA8EMU-618).
    try std.testing.expect(ended.count > 36_000);
    try std.testing.expectEqual(@as(u64, 0), ended.collapsed);
    try std.testing.expectEqual(ended.ticks, ended.count);
}
