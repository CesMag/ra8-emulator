//! One sizing run and the whole sweep (RA8EMU-645). The synthetic
//! workload's traffic goes through external_memory.Fabric as the Ethos-U55,
//! the same accounting a guest's OSPI and SDRAM accesses take on a run.
//! Weight chunks are double buffered the way Vela streams them, so a chunk
//! takes the longer of its compute and its memory traffic, and the stall is
//! what memory adds on top of compute.
const std = @import("std");
const external = @import("../external/memory.zig");
const workload = @import("workload.zig");
const matrix = @import("matrix.zig");

/// Free space a size must leave over the workload's high-water mark
/// (the RA8FW-666 target).
pub const headroom_percent: u64 = 25;

pub const Result = struct {
    total_ns: u64 = 0,
    npu_ns: u64 = 0,
    cpu_ns: u64 = 0,
    stall_ns: u64 = 0,
    flash_high_bytes: u64 = 0,
    sdram_high_bytes: u64 = 0,
    flash_bytes_read: u64 = 0,
    sdram_bytes_moved: u64 = 0,
};

pub const Row = struct {
    config: external.Config,
    result: Result,
    meets: bool,
};

pub const Summary = struct {
    flash_min_bytes: ?u64,
    sdram_min_bytes: ?u64,
    fastest: usize,
    /// The row with the longest time that is still inside the target.
    slowest_meeting: ?usize,
};

/// The workload on one board configuration.
pub fn runOne(job: workload.Synthetic, config: external.Config) !Result {
    try job.validate();
    var fabric = external.Fabric.init(try external.Layout.init(config));
    var result: Result = .{};
    var now: u64 = 0;
    for (0..job.passes) |_| {
        now = pass(job, &fabric, now, &result);
        const cpu = nanos(job.cpu_cycles_per_pass, job.cpu_hz);
        result.cpu_ns += cpu;
        now += cpu;
    }
    result.total_ns = now;
    const flash = fabric.counters(.ospi, now);
    const sdram = fabric.counters(.sdram, now);
    result.flash_high_bytes = flash.read_high_water_bytes;
    result.sdram_high_bytes = @max(sdram.read_high_water_bytes, sdram.write_high_water_bytes);
    result.flash_bytes_read = flash.bytes_read;
    result.sdram_bytes_moved = sdram.bytes_read + sdram.bytes_written;
    return result;
}

/// Every configuration in the matrix, each judged against `target_ns`
/// when there is one.
pub fn all(job: workload.Synthetic, target_ns: ?u64, rows: *[matrix.count]Row) !void {
    for (rows, 0..) |*row, index| {
        const config = matrix.at(index);
        const result = try runOne(job, config);
        const meets = if (target_ns) |target| result.total_ns <= target else true;
        row.* = .{ .config = config, .result = result, .meets = meets };
    }
}

pub fn summarize(rows: []const Row) Summary {
    var summary: Summary = .{
        .flash_min_bytes = fitSize(rows[0].result.flash_high_bytes, matrix.ospi_max_bytes),
        .sdram_min_bytes = fitSize(rows[0].result.sdram_high_bytes, matrix.sdram_max_bytes),
        .fastest = 0,
        .slowest_meeting = null,
    };
    for (rows, 0..) |row, index| {
        if (row.result.total_ns < rows[summary.fastest].result.total_ns) summary.fastest = index;
        if (!row.meets) continue;
        const slower = if (summary.slowest_meeting) |best| row.result.total_ns > rows[best].result.total_ns else true;
        if (slower) summary.slowest_meeting = index;
    }
    return summary;
}

/// The smallest power-of-two MiB a controller takes that holds `high`
/// bytes with the headroom, or null when even its ceiling does not.
pub fn fitSize(high: u64, max: u64) ?u64 {
    const want = high + (high * headroom_percent + 99) / 100;
    var size: u64 = workload.mib;
    while (size < want and size <= max) size *= 2;
    return if (size <= max) size else null;
}

fn pass(job: workload.Synthetic, fabric: *external.Fabric, start: u64, result: *Result) u64 {
    var now = start;
    const count = job.chunks();
    var offset: u64 = 0;
    var index: u64 = 0;
    while (offset < job.weights_bytes) : (index += 1) {
        const bytes = @min(job.chunk_bytes, job.weights_bytes - offset);
        fabric.setWall(now);
        fabric.note(.ethos_u55, .{ .kind = .ospi, .offset = @intCast(offset) }, .read, @intCast(bytes));
        const low = job.activations_bytes * index / count;
        const high = job.activations_bytes * (index + 1) / count;
        if (high > low) {
            const hit: external.Hit = .{ .kind = .sdram, .offset = @intCast(low) };
            fabric.note(.ethos_u55, hit, .read, @intCast(high - low));
            fabric.note(.ethos_u55, hit, .write, @intCast(high - low));
        }
        const memory = fabric.takePending(.ethos_u55);
        const macs = bytes * job.macs_per_weight_byte;
        const compute = nanos((macs + job.npu_macs_per_cycle - 1) / job.npu_macs_per_cycle, job.npu_hz);
        const chunk = @max(compute, memory);
        result.npu_ns += compute;
        result.stall_ns += chunk - compute;
        now += chunk;
        offset += bytes;
    }
    return now;
}

/// `cycles` at `hz`, in nanoseconds rounded up.
fn nanos(cycles: u64, hz: u64) u64 {
    const product = @as(u128, cycles) * external.wall_hz;
    const value = (product + hz - 1) / hz;
    return std.math.cast(u64, value) orelse std.math.maxInt(u64);
}
