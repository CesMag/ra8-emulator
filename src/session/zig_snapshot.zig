//! The `--save-state` / `--load-state` hook on a Zig run (RA8EMU-696): the
//! run file (src/board/snapshot/run.zig: board, CPU0's store, the core), the two
//! SysTick bases the run keeps beside the board (src/chip/snapshot/systick.zig)
//! and what the run owed its clocks (src/board/snapshot/stretch.zig, RA8EMU-700).
//!
//! `--snapshot-at` writes the same file at the first closed stretch at or
//! past its time, owing nothing, and the run goes on (RA8EMU-769).
//!
//! A run with `--cpu1` is refused: the second core lives in its own driver
//! and its state is not in the file yet.
const std = @import("std");
const backing = @import("../board/external_backing.zig");
const boot = @import("ra8_chip").core.cpu.boot;
const Cpu = @import("ra8_chip").core.cpu.cpu.Cpu;
const Store = @import("ra8_chip").core.cpu.memory.store.Store;
const run_file = @import("../board/snapshot/run.zig");
const systick = @import("ra8_chip").snapshot.systick;
const stretch = @import("../board/snapshot/stretch.zig");
const Clock = @import("run_clock.zig").Clock;

/// The largest file a load reads.
const max_bytes = 1 << 30;

pub const Error = error{SecondCoreNotSaved};

/// The hook for `clock`'s run, or null when neither flag was given.
pub fn hook(clock: *Clock) ?boot.Snapshot {
    if (!clock.state.wanted()) return null;
    return .{
        .context = clock,
        .loadFn = if (clock.state.load != null) load else null,
        .saveFn = if (clock.state.save != null) save else null,
        .dueFn = if (clock.state.at != null) due else null,
        .atFn = if (clock.state.at != null) writeAt else null,
    };
}

fn load(context: *anyopaque, core: *Cpu) anyerror!u32 {
    const clock: *Clock = @ptrCast(@alignCast(context));
    const store = try storeOf(clock);
    const allocator = std.heap.page_allocator;
    const bytes = try std.Io.Dir.cwd().readFileAlloc(clock.io, clock.state.load.?, allocator, .limited(max_bytes));
    defer allocator.free(bytes);
    try run_file.load(bytes, store, &.{core}, clock.board);
    try systick.load(.{ clock.timebase, &clock.ns_timebase }, bytes);
    const saved = try stretch.load(bytes);
    clock.accounted = core.retired -| saved.owed;
    clock.wall_cycles = if (backing.fabricOf(store)) |fabric| fabric.wall else 0;
    clock.cycle_remainder = saved.cycle_remainder;
    if (saved.owed != 0) {
        if (saved.rate_known) {
            clock.boundary_hz = saved.boundary_hz;
            clock.resume_unscaled = saved.boundary_hz == null;
        } else clock.resume_boundary = true;
    }
    return saved.owed;
}

fn save(context: *anyopaque, core: *const Cpu, owed: u32) anyerror!void {
    const clock: *Clock = @ptrCast(@alignCast(context));
    try write(clock, core, clock.state.save.?, owed);
}

fn due(context: *anyopaque) bool {
    const clock: *Clock = @ptrCast(@alignCast(context));
    const wanted = clock.state.at orelse return false;
    return !wanted.written and clock.board.time.base.now() >= wanted.ns;
}

fn writeAt(context: *anyopaque, core: *const Cpu) anyerror!void {
    const clock: *Clock = @ptrCast(@alignCast(context));
    const at = &clock.state.at.?;
    at.written = true;
    try write(clock, core, at.path, 0);
}

fn write(clock: *Clock, core: *const Cpu, path: []const u8, owed: u32) !void {
    const store = try storeOf(clock);
    const file = try std.Io.Dir.cwd().createFile(clock.io, path, .{});
    defer file.close(clock.io);
    var staging: [4096]u8 = undefined;
    var writer = file.writer(clock.io, &staging);
    const out = &writer.interface;
    try run_file.save(out, store, &.{core}, clock.board);
    try systick.save(.{ clock.timebase, &clock.ns_timebase }, out);
    try stretch.save(.{ .owed = owed, .cycle_remainder = clock.cycle_remainder, .boundary_hz = if (owed != 0) clock.boundary_hz else null }, out);
    try out.flush();
}

fn storeOf(clock: *const Clock) Error!*Store {
    if (clock.cpu1 != null) return Error.SecondCoreNotSaved;
    return clock.memory.store;
}
