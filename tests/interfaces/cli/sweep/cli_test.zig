//! Covers src/interfaces/cli/sweep_cli.zig, sweep_report.zig and
//! sweep_table.zig: the `sweep` flags and both forms of its report.
const std = @import("std");
const ra8 = @import("ra8");
const cli_app = @import("cli_app");

const sweep_cli = cli_app.sweep.cli;
const sizing = ra8.board.sizing;

test "the sweep flags set the workload, the target and the form" {
    const options = try sweep_cli.parse(&[_][]const u8{
        "--weights-mib", "8", "--activations-kib", "512", "--passes", "3", "--target-ms", "40", "--report", "json",
    });
    try std.testing.expectEqual(@as(u64, 8 * sizing.workload.mib), options.job.weights_bytes);
    try std.testing.expectEqual(@as(u64, 512 * sizing.workload.kib), options.job.activations_bytes);
    try std.testing.expectEqual(@as(u32, 3), options.job.passes);
    try std.testing.expectEqual(@as(?u64, 40_000_000), options.target_ns);
    try std.testing.expect(options.json);
    const plain = try sweep_cli.parse(&[_][]const u8{});
    try std.testing.expect(!plain.json);
    try std.testing.expectEqual(@as(?u64, null), plain.target_ns);
}

test "a bad sweep flag is refused" {
    const bad = [_][]const []const u8{
        &.{"--passes"},
        &.{ "--passes", "0" },
        &.{ "--frobs", "1" },
        &.{ "--report", "xml" },
        &.{ "--weights-mib", "512" },
    };
    for (bad) |args| try std.testing.expectError(error.BadArguments, sweep_cli.parse(args));
}

fn rows(job: sizing.workload.Synthetic, target: ?u64) ![sizing.matrix.count]sizing.sweep.Row {
    var out: [sizing.matrix.count]sizing.sweep.Row = undefined;
    try sizing.sweep.all(job, target, &out);
    return out;
}

test "the JSON report parses and carries the requirements" {
    var options = try sweep_cli.parse(&[_][]const u8{ "--weights-mib", "1", "--activations-kib", "64", "--target-ms", "10", "--report", "json" });
    options.job.weights_bytes = 256 * sizing.workload.kib;
    const table = try rows(options.job, options.target_ns);
    var buffer: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buffer.deinit();
    try sweep_cli.emit(&buffer.writer, options, &table);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, buffer.written(), .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    try std.testing.expectEqualStrings("memory_sizing", root.get("report").?.string);
    const needs = root.get("requirements").?.object;
    try std.testing.expectEqual(@as(i64, 256 * 1024), needs.get("flash_high_water_bytes").?.integer);
    try std.testing.expectEqual(@as(i64, 1024 * 1024), needs.get("flash_min_bytes").?.integer);
    try std.testing.expectEqual(@as(i64, 1024 * 1024), needs.get("sdram_min_bytes").?.integer);
    try std.testing.expectEqual(@as(usize, sizing.matrix.count), root.get("configs").?.array.items.len);
    const first = root.get("configs").?.array.items[0].object;
    try std.testing.expectEqual(@as(i64, 1), first.get("ospi_width_bits").?.integer);
    try std.testing.expect(first.get("memory_stall_ns").?.integer > 0);
}

test "the table names the minimums and one line per configuration" {
    var options = try sweep_cli.parse(&[_][]const u8{ "--activations-kib", "64" });
    options.job.weights_bytes = 256 * sizing.workload.kib;
    const table = try rows(options.job, null);
    var buffer: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buffer.deinit();
    try sweep_cli.emit(&buffer.writer, options, &table);
    const text = buffer.written();
    try std.testing.expect(std.mem.indexOf(u8, text, "flash: high water 262144 bytes, minimum with 25% headroom 1 MiB\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "  x1  41.66 MHz  x8   66.50 MHz CL2") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "slowest that meets the target: no target given\n") != null);
    try std.testing.expectEqual(@as(usize, sizing.matrix.count + 8), std.mem.count(u8, text, "\n"));
}
