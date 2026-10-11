//! Covers src/interfaces/cli/sweep/elf.zig and the `sweep --elf` flags:
//! the profile each child gets, reading a child's report, and real child
//! runs of tests/fixtures/sizing/ext_stream.elf on the slowest and fastest
//! configurations.
const std = @import("std");
const ra8 = @import("ra8");
const cli_app = @import("cli_app");
const test_paths = @import("test_paths");

const sweep_cli = cli_app.sweep.cli;
const sweep_elf = cli_app.sweep.elf;
const matrix = ra8.board.sizing.matrix;
const profile = ra8.board.profile;

const fixture = "tests/fixtures/sizing/ext_stream.elf";

test "--elf takes a path, one way to end, and a part" {
    const options = try sweep_cli.parse(&[_][]const u8{ "--elf", "a.elf", "--stop-sym", "done", "1", "--part", "ra8p1", "--report", "json" });
    const guest = options.elf.?;
    try std.testing.expectEqualStrings("a.elf", guest.path);
    try std.testing.expectEqualStrings("done", guest.stop_sym.?);
    try std.testing.expectEqualStrings("1", guest.stop_count);
    try std.testing.expectEqualStrings("ra8p1", guest.part);
    try std.testing.expect(options.json);
    const timed = try sweep_cli.parse(&[_][]const u8{ "--ms", "20", "--elf", "a.elf" });
    try std.testing.expectEqualStrings("20", timed.elf.?.ms.?);
    try std.testing.expectEqual(@as(?sweep_elf.Job, null), (try sweep_cli.parse(&[_][]const u8{})).elf);
}

test "a guest sweep without one way to end, or mixed with the synthetic flags, is refused" {
    const bad = [_][]const []const u8{
        &.{ "--elf", "a.elf" },
        &.{ "--elf", "a.elf", "--ms", "5", "--stop-sym", "done", "1" },
        &.{ "--elf", "a.elf", "--ms", "5", "--passes", "2" },
        &.{ "--elf", "a.elf", "--stop-sym", "done" },
        &.{ "--elf", "a.elf", "--stop-sym", "done", "many" },
        &.{ "--elf", "a.elf", "--ms", "5", "--part", "ra6m5" },
        &.{ "--ms", "5" },
    };
    for (bad) |args| try std.testing.expectError(error.BadArguments, sweep_cli.parse(args));
}

test "each child's profile is the EK profile with the row's memory" {
    var text: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer text.deinit();
    const config = matrix.at(0);
    try sweep_elf.profileText(&text.writer, config);
    const parsed = try profile.parse(text.written());
    try std.testing.expectEqual(config.ospi.width, parsed.memory.ospi.width);
    try std.testing.expectEqual(config.ospi.clock_hz, parsed.memory.ospi.clock_hz);
    try std.testing.expectEqual(config.sdram.width, parsed.memory.sdram.width);
    try std.testing.expectEqual(config.sdram.latency_cycles, parsed.memory.sdram.latency_cycles);
    try std.testing.expect(std.mem.indexOf(u8, text.written(), "companion=c6@uart:sci2\n") != null);
}

test "a row comes from the child's report after its text lines" {
    const stdout =
        \\loaded 162 bytes
        \\{"run":{"elapsed_cycles":2000},"memory":{"external_regions":[
        \\{"name":"ospi","bytes_read":64,"bytes_written":0,"read_high_water_bytes":64,"write_high_water_bytes":0,"stall_cycles":{"cpu":300,"ethos_u55":0}},
        \\{"name":"sdram","bytes_read":16,"bytes_written":32,"read_high_water_bytes":16,"write_high_water_bytes":32,"stall_cycles":{"cpu":200,"ethos_u55":0}}]}}
    ;
    const row = try sweep_elf.fromReport(std.testing.allocator, stdout);
    try std.testing.expectEqual(@as(u64, 2000), row.total_ns);
    try std.testing.expectEqual(@as(u64, 500), row.stall_ns);
    try std.testing.expectEqual(@as(u64, 64), row.flash_bytes_read);
    try std.testing.expectEqual(@as(u64, 48), row.sdram_bytes_moved);
    try std.testing.expectEqual(@as(u64, 32), row.sdram_high_bytes);
    try std.testing.expectError(error.NoReport, sweep_elf.fromReport(std.testing.allocator, "no report"));
}

test "the fixture moves the same bytes on every row and takes longer on slow memory" {
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();
    const base = try dir.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(base);
    const scratch = try std.fs.path.join(std.testing.allocator, &.{ base, "row.board" });
    defer std.testing.allocator.free(scratch);
    const job: sweep_elf.Job = .{ .path = fixture, .stop_sym = "ext_stream_done" };
    const slow = try sweep_elf.runOne(std.testing.allocator, std.testing.io, test_paths.emulator, job, matrix.at(0), scratch);
    const fast = try sweep_elf.runOne(std.testing.allocator, std.testing.io, test_paths.emulator, job, matrix.at(matrix.count - 1), scratch);
    for ([_]@TypeOf(slow){ slow, fast }) |row| {
        try std.testing.expectEqual(@as(u64, 64 * 1024), row.flash_bytes_read);
        try std.testing.expectEqual(@as(u64, 128 * 1024), row.sdram_bytes_moved);
    }
    try std.testing.expect(slow.total_ns > fast.total_ns);
    try std.testing.expect(slow.stall_ns > fast.stall_ns);
}
