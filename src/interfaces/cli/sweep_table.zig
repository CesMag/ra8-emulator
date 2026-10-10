//! The sizing sweep as a table a person reads (RA8EMU-645): what the
//! workload needs first, then one line per configuration with where its
//! time went. sweep_report.zig carries the same rows as JSON.
const std = @import("std");
const workload = @import("ra8_board").sizing.workload;
const sweep = @import("ra8_board").sizing.sweep;
const sweep_report = @import("sweep_report.zig");
const caveat = sweep_report.caveat;

pub fn write(out: anytype, source: sweep_report.Source, target_ns: ?u64, rows: []const sweep.Row) !void {
    const summary = sweep.summarize(rows);
    switch (source) {
        .synthetic => |job| try out.print("memory sizing sweep: {d} configurations, synthetic weight streaming, {d} KiB weights, {d} KiB activations, {d} pass(es)\n", .{
            rows.len, job.weights_bytes / workload.kib, job.activations_bytes / workload.kib, job.passes,
        }),
        .elf => |path| try out.print("memory sizing sweep: {d} configurations, guest image {s}\n", .{ rows.len, path }),
    }
    try out.print("flash: high water {d} bytes, minimum with {d}% headroom ", .{ rows[0].result.flash_high_bytes, sweep.headroom_percent });
    try size(out, summary.flash_min_bytes);
    try out.print("sdram: high water {d} bytes, minimum with {d}% headroom ", .{ rows[0].result.sdram_high_bytes, sweep.headroom_percent });
    try size(out, summary.sdram_min_bytes);
    try out.writeAll("target: ");
    if (target_ns) |target| try millis(out, target) else try out.writeAll("none");
    try out.writeAll("\n   #  ospi          sdram             total ms      npu ms      cpu ms    stall ms  target\n");
    for (rows, 0..) |row, index| try line(out, index, row, target_ns != null, source == .elf);
    try out.print("fastest: #{d}, ", .{summary.fastest});
    try millis(out, rows[summary.fastest].result.total_ns);
    try out.writeAll(" ms\nslowest that meets the target: ");
    if (target_ns == null) {
        try out.writeAll("no target given\n");
    } else if (summary.slowest_meeting) |index| try out.print("#{d}\n", .{index}) else try out.writeAll("none\n");
    try out.print("note: {s}\n", .{caveat});
}

fn line(out: anytype, index: usize, row: sweep.Row, judged: bool, guest: bool) !void {
    const result = row.result;
    try out.print("{d:>4}  x{d} ", .{ index, row.config.ospi.width });
    try mhz(out, row.config.ospi.clock_hz);
    try out.print("  x{d:<2} ", .{row.config.sdram.width});
    try mhz(out, row.config.sdram.clock_hz);
    try out.print(" CL{d}", .{row.config.sdram.latency_cycles});
    inline for (.{ "total_ns", "npu_ns", "cpu_ns", "stall_ns" }) |name| {
        try out.writeAll("  ");
        const compute = comptime !std.mem.eql(u8, name, "total_ns") and !std.mem.eql(u8, name, "stall_ns");
        if (guest and compute) try out.writeAll("         -") else try millis(out, @field(result, name));
    }
    const verdict = if (!judged) "-" else if (row.meets) "meets" else "misses";
    try out.print("  {s}\n", .{verdict});
}

fn size(out: anytype, bytes: ?u64) !void {
    if (bytes) |value| return out.print("{d} MiB\n", .{value / workload.mib});
    try out.writeAll("does not fit\n");
}

fn mhz(out: anytype, hz: u32) !void {
    try out.print("{d:>3}.{d:0>2} MHz", .{ hz / 1_000_000, hz / 10_000 % 100 });
}

fn millis(out: anytype, ns: u64) !void {
    try out.print("{d:>6}.{d:0>3}", .{ ns / 1_000_000, ns / 1_000 % 1_000 });
}
