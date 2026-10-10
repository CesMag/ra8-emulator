//! A `--cpu zig` run started from main, with the board's time wired in. This
//! charges SysTick, DWT_CYCCNT and the blocks at every chunk boundary, the
//! same boundary, so a ThreadX image gets its tick and the peripherals that
//! count time (the USB host script among them) move.
const std = @import("std");
const Guest = @import("ra8_chip").core.cpu.memory.guest.Guest;
const boot = @import("ra8_chip").core.cpu.boot;
const elf = @import("../../image/elf.zig");
const clocks = @import("ra8_chip").periph.clocks;
const fault_file = @import("../../session/fault_file.zig");
const cli = @import("cli.zig");
const Board = @import("../../board/board.zig").Board;
const board_wiring = @import("../../board/wiring.zig");
const report_run = @import("report/run.zig");
const json_run = @import("report/json_run.zig");
const report_dumps = @import("report/dumps.zig");
const frame_out = @import("frame_out.zig");
const frames_out = @import("report.zig").frames_out;
const eink_log = @import("eink_log.zig");
const audio_out = @import("audio_out.zig");
const rtos_hook = @import("../../session/rtos_hook.zig");
const run_loop = @import("../../session/run_loop.zig");
const second_core = @import("ra8_chip").core.second_core;
const profile = @import("../../session/profile.zig");
pub const stack_profile = @import("../../session/stack_profile.zig");
const mem_dump = @import("../../session/mem_dump.zig");
const watchpoint = @import("../../session/watchpoint.zig");
/// `--watch` on a Zig run: src/session/zig_watch.zig.
pub const zig_watch = @import("../../session/zig_watch.zig");
const Until = @import("ra8_chip").core.until.Until;
/// The `--stop-sym` counter a Zig run watches: src/session/zig_stop.zig.
pub const stop_sym = @import("../../session/zig_stop.zig");
/// Re-exported for tests/session/itm_console_test.zig: cli.zig is full.
pub const itm_console = @import("../../session/itm_console.zig");
/// The `--break-sym` arrival a Zig run counts: src/session/zig_break.zig.
pub const break_sym = @import("../../session/zig_break.zig");
/// `--stop-on-undefined` on a Zig run: src/session/zig_undefined.zig.
pub const undefined_sites = @import("../../session/zig_undefined.zig");
/// `--save-state` / `--load-state` (RA8EMU-696).
pub const state_args = @import("state_args.zig");
pub const zig_snapshot = @import("../../session/zig_snapshot.zig");

/// What ends a Zig run before its budget: src/session/run_loop.zig.
pub const Ends = run_loop.Ends;
/// A `--cpu zig` run from main, with no engine opened: RA8EMU-592.
pub const main_path = @import("zig_main.zig");

const BootWriter = struct {
    output: *std.Io.Writer,
    quiet: bool,

    pub fn print(self: BootWriter, comptime format: []const u8, args: anytype) !void {
        if (!self.quiet) try self.output.print(format, args);
    }

    pub fn writeAll(self: BootWriter, bytes: []const u8) !void {
        if (!self.quiet) try self.output.writeAll(bytes);
    }
};

pub const Clock = run_loop.Clock;

/// Run, then print what the board has to say.
/// `memory` is CPU0's store (RA8EMU-577); no engine is opened (RA8EMU-607).
pub fn run(out: *std.Io.Writer, io: std.Io, memory: Guest, board: *Board, timebase: *clocks.Clocks, image: elf.Image, options: cli.Options, vector_base: u32, profile_table: ?*profile.Table, until: ?*Until, ends: Ends) !u8 {
    var pair: second_core.zig_run.Driver = undefined;
    var cpu1: ?*second_core.zig_run.Driver = null;
    if (if (options.cpu == .zig) options.cpu1_path else null) |named| {
        if (!openSecond(&pair, io, board, named, memory, options.blocks)) return 1;
        cpu1 = &pair;
        rtos_hook.second.armZig(&pair, io, options.rtosWanted(), named);
    }
    defer if (cpu1) |second| second.close();
    var eink_recorder = eink_log.Run.init(std.heap.page_allocator, board);
    if (options.frames.eink_log != null) eink_recorder.arm();
    defer eink_recorder.deinit();
    var audio: audio_out.Run = .{};
    audio.arm(board, if (options.cpu == .zig) options.audio else .{});
    defer audio.deinit();
    const budget = options.budgetFor(ends.stop != null);
    var loop: run_loop.Loop = .{};
    try loop.run(BootWriter{ .output = out, .quiet = options.ctl_cpu_load }, out, io, memory, board, timebase, image, loopOptions(options, budget), vector_base, profile_table, until, cpu1, ends);
    const clock = &loop.clock;
    const final = &loop.final;
    const status = loop.status;
    const ran = &loop.ran;
    const tracer = &loop.tracer;
    const watched = try postBootReport(out, clock, &loop.watcher, final, image, options, ends, loop.retire.at, budget);
    if (options.cpu == .zig) {
        // The core lent its retired count; `ran` holds the final count.
        if (tracer.*) |*found| found.trace.fine = ran;
        if (options.ctl_cpu_load) return ctlLoad(out, loadOf(clock.memory, if (tracer.*) |*found| found else null, clock.cpu1), status);
        var frames = try frames_out.Run.initForCli(std.heap.page_allocator, io, board, options.frames);
        defer frames.deinit(board);
        if (options.report_json) {
            const load = loadOf(clock.memory, if (tracer.*) |*found| found else null, clock.cpu1);
            try json_run.document(out, board, .{ .engine = "zig", .elapsed = ran.*, .elapsed_cycles = clock.wall_cycles, .external = clock.memory, .bus_errors = clock.bus_tally, .where = .{ .image = image, .profile = profile_table }, .dumps = &.{ .registers = .{ .zig = final }, .memory = clock.memory, .image = image, .options = &options, .io = io, .watched = watched }, .load = if (options.cpu_load) &load else null, .eink_log = if (options.frames.eink_log != null) &eink_recorder else null });
        } else try report_run.zigCore(out, board, timebase.*, ran.*, clock.bus_tally);
        try report_run.cpu1(out, if (clock.cpu1) |second| &second.second else null);
        // Globals a memory-probe verdict reads, out of the Zig core's memory.
        if (!options.report_json) try textDumps(out, io, board, clock.memory, final, image, options, watched);
        if (tracer.*) |*found| try rtos_hook.report.all(out, io, options, found, rtos_hook.Memory{ .guest = clock.memory });
        if (clock.cpu1) |second| try rtos_hook.second.printOn(out, io, options, second.guest());
        try finishFrames(out, io, board, options, &frames, &audio);
    } else if (options.ctl_cpu_load) {
        return ctlLoad(out, .{}, status);
    } else try captureFrames(board, io, options);
    try finishEinkLog(out, io, options, &eink_recorder);
    return status;
}

/// The loop's options, read off the CLI's.
fn loopOptions(options: cli.Options, budget: usize) run_loop.Options {
    return .{ .cpu = options.cpu, .blocks = options.blocks, .rtos = options.rtosWanted(), .watch_place = options.watch_place, .idle_skip = options.idle_skip, .state = options.state, .console = options.console, .bus_errors = options.bus_errors, .budget = budget };
}

fn postBootReport(out: *std.Io.Writer, clock: *Clock, watcher: *zig_watch.Recorder, final: *const boot.Regs, image: elf.Image, options: cli.Options, ends: Ends, retire_at: u32, budget: usize) !?watchpoint.Watched {
    clock.soakFaults();
    const watched = watcher.result(final.pc);
    clock.board.run.soak.place(final.pc, if (clock.board.clock.running()) clock.board.clock.now else null);
    const said = BootWriter{ .output = out, .quiet = options.ctl_cpu_load };
    if (ends.point) |point| {
        try break_sym.verdict(said, options.break_place.?, point.*, retire_at, final.pc, budget);
    } else try stop_sym.verdict(said, options.stop_symbol, if (ends.stop) |watch| watch.* else null, if (ends.timed) |due| due.* else null, final.pc, budget);
    if (ends.undefined_sites) |found| try @import("report/undefined.zig").print(said, image, found.*);
    return watched;
}

fn finishEinkLog(out: *std.Io.Writer, io: std.Io, options: cli.Options, recorder: *eink_log.Run) !void {
    const path = options.frames.eink_log orelse return;
    try recorder.write(io, path);
    if (!options.report_json) try recorder.printTotals(out);
}

/// Bring CPU1 up from `named`, with its block cache when asked; false once
/// the reason it could not is printed.
fn openSecond(pair: *second_core.zig_run.Driver, io: std.Io, board: *Board, named: []const u8, memory: Guest, blocks: bool) bool {
    @import("cpu1_image.zig").open(pair, std.heap.page_allocator, io, board_wiring.cpu1(board), named, memory) catch |err| {
        std.debug.print("cannot bring up the second core from {s}: {s}\n", .{ named, @errorName(err) });
        return false;
    };
    if (blocks) pair.core.useBlocks() catch |err| {
        pair.close();
        std.debug.print("cannot give the second core its block cache: {s}\n", .{@errorName(err)});
        return false;
    };
    return true;
}

/// The flag-asked dumps of a text run, in the engine report's order
/// (RA8EMU-638): globals, the card block, registers, memory words, then
/// what landed in the `--watch` word (RA8EMU-639).
fn textDumps(out: *std.Io.Writer, io: std.Io, board: *Board, memory: Guest, final: *const boot.Regs, image: elf.Image, options: cli.Options, watched: ?watchpoint.Watched) !void {
    try report_dumps.dumpSymbols(out, io, memory, image, options);
    try report_dumps.dumpBlock(out, board, options);
    try report_dumps.dumpRegisters(out, .{ .zig = final }, memory, options);
    try mem_dump.printAll(out, memory, &board.bus, image, options.memDumps());
    try watchpoint.print(out, image, options.watch_place, watched);
}

fn finishFrames(out: *std.Io.Writer, io: std.Io, board: *Board, options: cli.Options, frames: *frames_out.Run, audio: *audio_out.Run) !void {
    try frames.finish(board);
    try audio.finish(out, io);
    try frame_out.report(out, io, board, options.frame_out, options.panel_only);
}

fn captureFrames(board: *Board, io: std.Io, options: cli.Options) !void {
    var frames = try frames_out.Run.initForCli(std.heap.page_allocator, io, board, options.frames);
    defer frames.deinit(board);
    try frames.finish(board);
}

/// `ctl cpu-load` prints only the load object, then the run's status.
fn ctlLoad(out: *std.Io.Writer, load: json_run.json_load.Load, status: u8) !u8 {
    try json_run.json_load.document(out, &load);
    return status;
}

/// The traced cores `--cpu-load` reads under `--report json` (RA8EMU-266).
fn loadOf(memory: Guest, tracer: ?*const rtos_hook.Tracer, cpu1: ?*second_core.zig_run.Driver) json_run.json_load.Load {
    return .{
        .cpu0 = rtos_hook.report.sideOf(tracer, .{ .guest = memory }),
        .cpu1 = if (cpu1) |pair| rtos_hook.second.sideOn(pair.guest()) else null,
    };
}
