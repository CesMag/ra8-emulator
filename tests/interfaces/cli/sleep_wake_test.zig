//! RA8EMU-655, the idle-skip half of RA8EMU-569's done condition: an image
//! that sleeps ten virtual minutes in WFI on one timer wakes on time, and
//! the host gets there in well under a second.
//!
//! The image is idler.zig (the built-in sleep-and-count image the other
//! time tests use) with SysTick reloaded to one ten-minute period. SysTick
//! is 24 bits wide, so the core clock is set to 25 kHz: 600 s is then
//! 15,000,000 cycles, which fits. Nothing else is pending, so idle skip
//! (RA8EMU-185) runs each sleeping stretch straight to the next edge.
const std = @import("std");
const ra8 = @import("ra8");
const cli_app = @import("cli_app");
const idler = @import("idler.zig");
const store_board = @import("store_board.zig");

const zig_run = cli_app.zig_run;
const cpu_boot = ra8.chip.core.cpu.boot;

const hz: u64 = 25_000;
const sleep_s: u64 = 600;
const period: u64 = sleep_s * hz;
const ns_per_s: u64 = 1_000_000_000;

const Woke = struct { wakes: u32, virtual_ns: u64, host_ns: u64 };

/// Runs the image for `seconds` of virtual time with idle skip on.
fn sleepFor(seconds: u64) !Woke {
    var store = try store_board.Store.init(null);
    defer store.deinit();
    const core: store_board.Guest = .{ .store = &store };
    try idler.load(core);
    try core.writeWord(ra8.chip.core.memmap.syst.rvr, @intCast(period - 1));
    var board = ra8.board.board.Board.init(std.testing.allocator);
    defer board.deinit();
    try store_board.attach(&board, core);
    board.time.base.setRate(hz);
    var timebase: ra8.chip.periph.clocks.Clocks = .{ .per_chunk = idler.chunk };
    var clock: zig_run.Clock = .{ .io = std.testing.io, .memory = core, .board = &board, .timebase = &timebase, .idle_skip = true };
    var ran: u64 = 0;
    var output: [1024]u8 = undefined;
    var stream: std.Io.Writer = .fixed(&output);
    const started = std.Io.Timestamp.now(std.testing.io, .awake);
    _ = try cpu_boot.start(&stream, .zig, core, &board.bus, idler.base, seconds * hz, &ran, .{ .boundary = clock.boundary() });
    const host_ns: u64 = @intCast(started.durationTo(std.Io.Timestamp.now(std.testing.io, .awake)).toNanoseconds());
    return .{ .wakes = try core.readWord(idler.counter_at), .virtual_ns = board.time.base.now(), .host_ns = host_ns };
}

// The first wake lands at the start: idler.zig enables SysTick with CVR at
// zero, and this model wraps on that first reload. The ten-minute sleep is
// measured from there, against a one-second baseline run.
test "a ten-minute sleep wakes once more, at ten virtual minutes, in under a host second" {
    const baseline = try sleepFor(1);
    const woke = try sleepFor(sleep_s + 1);
    try std.testing.expectEqual(baseline.wakes + 1, woke.wakes);
    try std.testing.expect(woke.virtual_ns >= sleep_s * ns_per_s);
    try std.testing.expect(woke.host_ns < ns_per_s);
}

test "a second short of ten minutes, the sleeper has not woken again" {
    const baseline = try sleepFor(1);
    const woke = try sleepFor(sleep_s - 1);
    try std.testing.expectEqual(baseline.wakes, woke.wakes);
}
