//! `ra8_emulator sweep` (RA8EMU-645): run the synthetic weight-streaming
//! workload across every board memory configuration the RA8P1 controllers
//! support and print the sizing report, a table by default or JSON with
//! `--report json`. `--elf PATH` runs a guest image across the same matrix
//! instead (sweep_elf.zig).
const std = @import("std");
const workload = @import("ra8_board").sizing.workload;
const matrix = @import("ra8_board").sizing.matrix;
const sweep = @import("ra8_board").sizing.sweep;
const sweep_report = @import("sweep_report.zig");
const sweep_table = @import("sweep_table.zig");
const sweep_elf = @import("sweep_elf.zig");

pub const usage =
    \\usage: ra8_emulator sweep [--weights-mib N] [--activations-kib N] [--passes N]
    \\                          [--target-ms N] [--report table|json]
    \\       ra8_emulator sweep --elf PATH (--stop-sym NAME N | --ms N) [--part ra8d2|ra8p1]
    \\                          [--target-ms N] [--report table|json]
    \\
;

pub const Options = struct {
    job: workload.Synthetic = .{},
    elf: ?sweep_elf.Job = null,
    target_ns: ?u64 = null,
    json: bool = false,
};

/// The flags after `sweep`, each a name and a value (`--stop-sym` takes two).
pub fn parse(args: anytype) !Options {
    var options: Options = .{};
    var guest: sweep_elf.Job = .{ .path = "" };
    var synthetic = false;
    var index: usize = 0;
    while (index < args.len) {
        if (index + 1 >= args.len) return error.BadArguments;
        const flag: []const u8 = args[index];
        const value: []const u8 = args[index + 1];
        index += 2;
        if (std.mem.eql(u8, flag, "--report")) {
            options.json = if (std.mem.eql(u8, value, "json")) true else if (std.mem.eql(u8, value, "table")) false else return error.BadArguments;
        } else if (std.mem.eql(u8, flag, "--elf")) {
            guest.path = value;
        } else if (std.mem.eql(u8, flag, "--part")) {
            if (!std.mem.eql(u8, value, "ra8d2") and !std.mem.eql(u8, value, "ra8p1")) return error.BadArguments;
            guest.part = value;
        } else if (std.mem.eql(u8, flag, "--stop-sym")) {
            if (index >= args.len) return error.BadArguments;
            _ = std.fmt.parseInt(u64, args[index], 10) catch return error.BadArguments;
            guest.stop_sym = value;
            guest.stop_count = args[index];
            index += 1;
        } else if (std.mem.eql(u8, flag, "--ms")) {
            _ = std.fmt.parseInt(u64, value, 10) catch return error.BadArguments;
            guest.ms = value;
        } else if (std.mem.eql(u8, flag, "--target-ms")) {
            const number = std.fmt.parseInt(u64, value, 10) catch return error.BadArguments;
            options.target_ns = std.math.mul(u64, number, 1_000_000) catch return error.BadArguments;
        } else {
            try syntheticFlag(&options.job, flag, value);
            synthetic = true;
        }
    }
    options.job.validate() catch return error.BadArguments;
    const asked_guest = guest.path.len != 0 or guest.stop_sym != null or guest.ms != null or !std.mem.eql(u8, guest.part, "ra8d2");
    if (!asked_guest) return options;
    const one_end = (guest.stop_sym != null) != (guest.ms != null);
    if (synthetic or guest.path.len == 0 or !one_end) return error.BadArguments;
    options.elf = guest;
    return options;
}

fn syntheticFlag(job: *workload.Synthetic, flag: []const u8, value: []const u8) !void {
    const number = std.fmt.parseInt(u64, value, 10) catch return error.BadArguments;
    if (std.mem.eql(u8, flag, "--weights-mib")) {
        job.weights_bytes = std.math.mul(u64, number, workload.mib) catch return error.BadArguments;
    } else if (std.mem.eql(u8, flag, "--activations-kib")) {
        job.activations_bytes = std.math.mul(u64, number, workload.kib) catch return error.BadArguments;
    } else if (std.mem.eql(u8, flag, "--passes")) {
        job.passes = std.math.cast(u32, number) orelse return error.BadArguments;
    } else return error.BadArguments;
}

/// The whole command: argv[0] is the program, argv[1] is "sweep".
pub fn run(io: std.Io, env: *const std.process.Environ.Map, argv: anytype) !u8 {
    const options = parse(argv[2..]) catch {
        try std.Io.File.stderr().writeStreamingAll(io, usage);
        return 2;
    };
    var rows: [matrix.count]sweep.Row = undefined;
    if (options.elf) |guest| {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        sweep_elf.all(arena.allocator(), io, env, guest, options.target_ns, &rows) catch |err| {
            std.debug.print("sweep: running {s} failed: {s}\n", .{ guest.path, @errorName(err) });
            return 1;
        };
    } else try sweep.all(options.job, options.target_ns, &rows);
    var buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(io, &buffer);
    try emit(&stdout.interface, options, &rows);
    try stdout.interface.flush();
    return 0;
}

/// The report the options asked for, over `out`.
pub fn emit(out: anytype, options: Options, rows: []const sweep.Row) !void {
    const source: sweep_report.Source = if (options.elf) |guest| .{ .elf = guest.path } else .{ .synthetic = options.job };
    if (options.json) return sweep_report.document(out, source, options.target_ns, rows);
    try sweep_table.write(out, source, options.target_ns, rows);
}
