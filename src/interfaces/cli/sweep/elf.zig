//! `ra8_emulator sweep --elf PATH` (RA8EMU-755): run a real image once per
//! board memory configuration instead of the synthetic workload. Each run
//! is a child `ra8_emulator` on the Zig core with a version-1 board profile
//! that differs from the EK profile only in its OSPI and SDRAM lines, and
//! its row comes from the child's JSON report: wall time, the CPU's stall
//! on both regions, and the external_regions counters.
const std = @import("std");
const external = @import("ra8_board").external_memory;
const matrix = @import("ra8_board").sizing.matrix;
const sweep = @import("ra8_board").sizing.sweep;

const ek_profile = @import("ra8_board").profile.ek_ra8d2;
const max_report_bytes = 64 * 1024 * 1024;

/// What each child run is told: the image, the part, and how the run ends
/// (a `--stop-sym` counter, or `--ms` of the image's own time).
pub const Job = struct {
    path: []const u8,
    part: []const u8 = "ra8d2",
    stop_sym: ?[]const u8 = null,
    stop_count: []const u8 = "1",
    ms: ?[]const u8 = null,
};

/// The EK profile with `config`'s OSPI, SDRAM and window lines.
pub fn profileText(out: anytype, config: external.Config) !void {
    var lines = std.mem.splitScalar(u8, ek_profile, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "ospi=")) {
            try region(out, "ospi", config.ospi);
        } else if (std.mem.startsWith(u8, line, "sdram=")) {
            try region(out, "sdram", config.sdram);
        } else if (std.mem.startsWith(u8, line, "memory_window_cycles=")) {
            try out.print("memory_window_cycles={d}\n", .{config.window_cycles});
        } else if (line.len != 0) try out.print("{s}\n", .{line});
    }
}

fn region(out: anytype, name: []const u8, one: external.RegionConfig) !void {
    try out.print("{s}=size:{d},width:{d},clock_hz:{d},latency_cycles:{d},burst:{s}\n", .{
        name, one.size, one.width, one.clock_hz, one.latency_cycles, @tagName(one.burst),
    });
}

/// One child run of `exe` on `config`, with its profile at `scratch`.
pub fn runOne(gpa: std.mem.Allocator, io: std.Io, exe: []const u8, job: Job, config: external.Config, scratch: []const u8) !sweep.Result {
    {
        const file = try std.Io.Dir.cwd().createFile(io, scratch, .{});
        defer file.close(io);
        var buffer: [1024]u8 = undefined;
        var writer = file.writerStreaming(io, &buffer);
        try profileText(&writer.interface, config);
        try writer.interface.flush();
    }
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.appendSlice(gpa, &.{ exe, job.path, "--cpu", "zig", "--part", job.part, "--board-profile", scratch, "--report", "json" });
    if (job.stop_sym) |name| try argv.appendSlice(gpa, &.{ "--stop-sym", name, job.stop_count });
    if (job.ms) |ms| try argv.appendSlice(gpa, &.{ "--ms", ms });
    const ran = try std.process.run(gpa, io, .{ .argv = argv.items, .stdout_limit = .limited(max_report_bytes), .stderr_limit = .limited(max_report_bytes) });
    defer gpa.free(ran.stdout);
    defer gpa.free(ran.stderr);
    switch (ran.term) {
        .exited => |code| if (code != 0) return error.ChildFailed,
        else => return error.ChildFailed,
    }
    return fromReport(gpa, ran.stdout);
}

/// A row's numbers from a child's stdout: text lines, then the report.
pub fn fromReport(gpa: std.mem.Allocator, stdout: []const u8) !sweep.Result {
    const start = std.mem.indexOfScalar(u8, stdout, '{') orelse return error.NoReport;
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, stdout[start..], .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    var result: sweep.Result = .{ .total_ns = try number(root.get("run"), "elapsed_cycles") };
    const regions = (root.get("memory") orelse return error.NoReport).object.get("external_regions") orelse return error.NoReport;
    for (regions.array.items) |item| {
        const name = item.object.get("name").?.string;
        const stall = try number(item.object.get("stall_cycles"), "cpu");
        result.stall_ns += stall;
        const read = try number(item, "bytes_read");
        const read_high = try number(item, "read_high_water_bytes");
        if (std.mem.eql(u8, name, "ospi")) {
            result.flash_bytes_read = read;
            result.flash_high_bytes = read_high;
        } else if (std.mem.eql(u8, name, "sdram")) {
            result.sdram_bytes_moved = read + try number(item, "bytes_written");
            result.sdram_high_bytes = @max(read_high, try number(item, "write_high_water_bytes"));
        }
    }
    return result;
}

fn number(value: ?std.json.Value, field: []const u8) !u64 {
    const object = (value orelse return error.NoReport).object;
    const got = object.get(field) orelse return error.NoReport;
    return std.math.cast(u64, got.integer) orelse error.NoReport;
}

/// Every configuration in the matrix, each judged against `target_ns`.
pub fn all(gpa: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, job: Job, target_ns: ?u64, rows: *[matrix.count]sweep.Row) !void {
    const exe = try std.process.executablePathAlloc(io, gpa);
    defer gpa.free(exe);
    var tag: [8]u8 = undefined;
    io.random(&tag);
    const scratch = try std.fmt.allocPrint(gpa, "{s}/ra8-sweep-{x}.board", .{ env.get("TMPDIR") orelse "/tmp", std.mem.readInt(u64, &tag, .little) });
    defer gpa.free(scratch);
    defer std.Io.Dir.cwd().deleteFile(io, scratch) catch {};
    for (rows, 0..) |*row, index| {
        const config = matrix.at(index);
        const result = try runOne(gpa, io, exe, job, config, scratch);
        const meets = if (target_ns) |target| result.total_ns <= target else true;
        row.* = .{ .config = config, .result = result, .meets = meets };
    }
}
