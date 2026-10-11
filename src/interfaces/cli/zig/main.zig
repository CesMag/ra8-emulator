//! Every run from main, on the Zig core
//! (RA8EMU-592, slice 4e-2 of RA8EMU-481).
//!
//! CPU0 goes on its own store (src/board/cpu0_store.zig), the
//! opening line reads SP and the reset vector off that store, option memory
//! is read from it, and src/interfaces/cli/zig/run.zig gets no engine.
const std = @import("std");
const elf = @import("ra8_board").image.elf;
const Guest = @import("ra8_chip").core.cpu.memory.guest.Guest;
const Reboot = @import("ra8_chip").core.reboot.Reboot;
const Board = @import("ra8_board").board.Board;
const option_memory = @import("ra8_chip").periph.iwdt.option_memory;
const cli = @import("../cli.zig");
const Parts = @import("../parts.zig").Parts;
const report = @import("../report.zig");
const zig_run = @import("run.zig");
const dumps = @import("../report/dumps.zig");
const Stop = @import("ra8_chip").core.stop.Stop;
const fault_file = @import("ra8_session").fault_file;
const Cpu0 = @import("ra8_board").cpu0_store.Cpu0;

/// Fitting the board is shared with main's engine path.
pub const fit = @import("../board_fit.zig").fit;
const fit_verdict = @import("../board_fit.zig").tapeVerdict;
const policyOf = @import("../board_fit.zig").policy;

/// The whole run, in the order main's engine path takes it: fit the board,
/// load, announce, then run on the Zig core.
pub fn run(allocator: std.mem.Allocator, io: std.Io, image: elf.Image, options: cli.Options) !u8 {
    var board = Board.init(allocator);
    defer board.deinit();
    fit(&board, allocator, io, options) catch return 2;
    var asked = policyOf(&board, io, options);
    asked.attach(&board);
    defer cli.card.setup.saveBack(&board, io, options.sd_path, options.sd_save);
    defer cli.card.setup.saveSdhi(&board, io, options.sdhi);
    var cpu0: Cpu0 = .{};
    defer cpu0.close();
    var parts = Parts{};
    defer parts.deinit();
    const written = try prepare(&cpu0, &board, io, image, &parts, options);
    if (options.ns_path) |path| loadNonSecure(allocator, io, &cpu0, path) catch return 1;
    const vector_base = vectorBase(image) catch return 1;
    const memory = cpu0.own();
    var stdout = std.Io.File.stdout().writerStreaming(io, &.{});
    const out = &stdout.interface;
    try announce(out, memory, written, vector_base, options.ctl_cpu_load);
    var reboot = Reboot{ .vector_base = vector_base };
    board.reboot = &reboot;
    const table = if (parts.profile) |*one| one else null;
    var stop = stopOf(image, io, options);
    var point = zig_run.break_sym.resolve(image, options.break_place, options.break_arrival);
    var timed = zig_run.stop_sym.deadline(options.ms);
    var swept = zig_run.undefined_sites.resolve(image, options.stop_on_undefined);
    var schedule: fault_file.Run = undefined;
    if (options.faults) |path| schedule.open(&board, io, path) catch return 2;
    defer if (options.faults != null) schedule.deinit();
    if (options.count_pc_len != 0) for (options.count_pc[0..options.count_pc_len]) |at| parts.hits.want(at & ~@as(u32, 1));
    const ends: zig_run.Ends = .{
        .stop = if (stop) |*watch| watch else null,
        .point = if (point) |*one| one else null,
        .hits = if (options.count_pc_len != 0) &parts.hits else null,
        .timed = if (timed) |*due| due else null,
        .undefined_sites = if (swept) |*found| found else null,
        .schedule = if (options.faults != null) &schedule.applier else null,
        .policy = &asked,
    };
    return fit_verdict(&board, try zig_run.run(out, io, memory, &board, &parts.timebase, image, options, vector_base, table, parts.tap.waiting(), ends));
}

/// CPU0's store, the console tap, the profile table and option memory: what
/// main's `loadAll` sets up that a Zig run reads. Returns the bytes loaded.
pub fn prepare(cpu0: *Cpu0, board: *Board, io: std.Io, image: elf.Image, parts: *Parts, options: cli.Options) !u32 {
    const written = try cpu0.attachStore(board, image);
    if (options.console) board.console_input.source = cli.host.bytes.stdin();
    board.console_input.reply = options.console_reply;
    parts.tap = .{ .echo = if (options.console) io else null, .wait = if (options.until) |text| .{ .needle = text } else null };
    if (options.console_reply.armed()) parts.tap.reply = &board.console_input.reply;
    cli.console_output.configure(&board.serial.line, &parts.tap);
    if (options.profile) try parts.prepareProfile(io, image, options.profile_folded != null, if (options.cpu == .zig) options.cpu1_path else null);
    option_memory.apply(&board.heartbeat, cpu0.own());
    if (!options.ctl_cpu_load) _ = try report.frames.out.Armed.armForCli(std.heap.page_allocator, io, board, options.frames);
    return written;
}

/// Where the image's vector table is, or a printed complaint when it has
/// no executable segment to reset into. Shared with main's engine path.
pub fn vectorBase(image: elf.Image) error{NoVectors}!u32 {
    return image.vectorBase() orelse {
        std.debug.print("no executable segment, nothing to reset into\n", .{});
        return error.NoVectors;
    };
}

/// A TrustZone build's Non-Secure half (`--ns`), beside the main image.
fn loadNonSecure(allocator: std.mem.Allocator, io: std.Io, cpu0: *Cpu0, path: []const u8) !void {
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(64 * 1024 * 1024)) catch |err| {
        std.debug.print("cannot open {s}: {s}\n", .{ path, @errorName(err) });
        return err;
    };
    const ns = elf.Image.init(bytes) catch |err| {
        std.debug.print("{s} is not a loadable image: {s}\n", .{ path, @errorName(err) });
        return err;
    };
    try cpu0.load(ns);
}

/// The opening line, read off the store the way the engine's reset read it:
/// SP from the vector table, PC from the reset vector with its Thumb bit off.
/// Unbuffered, so it interleaves in order with the `--console` echo.
pub fn announce(out: *std.Io.Writer, memory: Guest, written: u32, vector_base: u32, quiet: bool) !void {
    if (quiet) return;
    const sp = try memory.readWord(vector_base);
    const pc = (try memory.readWord(vector_base + 4)) & ~@as(u32, 1);
    try out.print("loaded {d} bytes, vectors at 0x{X:0>8}, sp 0x{X:0>8}, pc 0x{X:0>8}\n", .{ written, vector_base, sp, pc });
}

/// The `--stop-sym` counter, with the `--ns` image read only when a name was
/// asked for and dropped once it is looked up.
fn stopOf(image: elf.Image, io: std.Io, options: cli.Options) ?Stop {
    if (options.stop_symbol == null) return null;
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const non_secure = dumps.nonSecure(arena.allocator(), io, options) catch null;
    return zig_run.stop_sym.resolve(image, non_secure, options.stop_symbol, options.stop_at);
}
