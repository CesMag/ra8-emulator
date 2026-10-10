//! Covers src/board/sizing: the synthetic workload, the configuration matrix and
//! the sweep that times one against the other (RA8EMU-645).
const std = @import("std");
const ra8 = @import("ra8");

const sizing = ra8.board.sizing;
const workload = sizing.workload;
const matrix = sizing.matrix;
const sweep = sizing.sweep;
const external = ra8.board.external_memory;

fn small() workload.Synthetic {
    return .{ .weights_bytes = workload.mib, .activations_bytes = 64 * workload.kib };
}

test "every matrix configuration is one a board profile would accept" {
    try std.testing.expectEqual(@as(usize, 144), matrix.count);
    for (0..matrix.count) |index| try matrix.at(index).validate();
    const first = matrix.at(0);
    try std.testing.expectEqual(@as(u8, 1), first.ospi.width);
    try std.testing.expectEqual(@as(u32, 41_666_667), first.ospi.clock_hz);
    try std.testing.expectEqual(@as(u8, 2), first.sdram.latency_cycles);
    const last = matrix.at(matrix.count - 1);
    try std.testing.expectEqual(@as(u8, 8), last.ospi.width);
    try std.testing.expectEqual(@as(u32, 133_000_000), last.sdram.clock_hz);
    try std.testing.expectEqual(@as(u8, 3), last.sdram.latency_cycles);
}

test "a run counts the workload's bytes exactly and splits its time" {
    const result = try sweep.runOne(small(), matrix.at(matrix.count - 1));
    try std.testing.expectEqual(@as(u64, workload.mib), result.flash_high_bytes);
    try std.testing.expectEqual(@as(u64, workload.mib), result.flash_bytes_read);
    try std.testing.expectEqual(@as(u64, 64 * workload.kib), result.sdram_high_bytes);
    try std.testing.expectEqual(@as(u64, 128 * workload.kib), result.sdram_bytes_moved);
    // 16 chunks of 64 KiB, each 64 KiB * 64 MACs / 256 per cycle at 500 MHz.
    try std.testing.expectEqual(@as(u64, 16 * 32_768), result.npu_ns);
    try std.testing.expectEqual(@as(u64, 2_000_000), result.cpu_ns);
    try std.testing.expectEqual(result.npu_ns + result.cpu_ns + result.stall_ns, result.total_ns);
}

test "slower memory takes longer for the same compute" {
    const slow = try sweep.runOne(small(), matrix.at(0));
    const fast = try sweep.runOne(small(), matrix.at(matrix.count - 1));
    try std.testing.expectEqual(slow.npu_ns, fast.npu_ns);
    try std.testing.expect(slow.stall_ns > fast.stall_ns);
    try std.testing.expect(slow.total_ns > fast.total_ns);
}

test "the minimum size keeps a quarter free and stays inside the controller" {
    try std.testing.expectEqual(@as(?u64, workload.mib), sweep.fitSize(0, matrix.sdram_max_bytes));
    try std.testing.expectEqual(@as(?u64, 2 * workload.mib), sweep.fitSize(workload.mib, matrix.ospi_max_bytes));
    try std.testing.expectEqual(@as(?u64, workload.mib), sweep.fitSize(800 * workload.kib, matrix.ospi_max_bytes));
    try std.testing.expectEqual(@as(?u64, null), sweep.fitSize(120 * workload.mib, matrix.sdram_max_bytes));
}

test "the summary names the slowest configuration still inside the target" {
    var job = small();
    job.weights_bytes = 256 * workload.kib;
    var rows: [matrix.count]sweep.Row = undefined;
    try sweep.all(job, null, &rows);
    const fastest = sweep.summarize(&rows).fastest;
    const target = rows[fastest].result.total_ns * 2;
    try sweep.all(job, target, &rows);
    const summary = sweep.summarize(&rows);
    const pick = summary.slowest_meeting.?;
    try std.testing.expect(rows[pick].result.total_ns <= target);
    for (rows) |row| {
        if (row.meets) try std.testing.expect(row.result.total_ns <= rows[pick].result.total_ns);
        if (!row.meets) try std.testing.expect(row.result.total_ns > target);
    }
}

test "a workload bigger than the controllers is refused" {
    var job = small();
    job.weights_bytes = 512 * workload.mib;
    try std.testing.expectError(error.BadWeights, sweep.runOne(job, external.Config{}));
}
