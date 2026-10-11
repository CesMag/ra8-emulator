//! The sizing sweep's JSON document (RA8EMU-645): the workload, the
//! requirements it implies and every configuration's time, in one object
//! an agent can parse. sweep_table.zig prints the same rows for a person.
const json = @import("../report/json/json.zig");
const workload = @import("ra8_board").sizing.workload;
const sweep = @import("ra8_board").sizing.sweep;

pub const caveat = "sizes and byte counts are exact; timing is as good as the memory timing parameters, " ++
    "which come from the candidate parts' datasheets until RA8P1 silicon exists";

/// What the rows were measured on: the synthetic workload, or a guest
/// image run once per configuration (sweep_elf.zig).
pub const Source = union(enum) {
    synthetic: workload.Synthetic,
    elf: []const u8,
};

pub fn document(out: anytype, source: Source, target_ns: ?u64, rows: []const sweep.Row) !void {
    const summary = sweep.summarize(rows);
    var j = json.over(out);
    try j.open(null, '{');
    try j.field("report", "memory_sizing");
    try j.field("caveat", caveat);
    try describe(&j, source);
    try j.field("target_ns", target_ns);
    try j.open("requirements", '{');
    try j.field("flash_high_water_bytes", rows[0].result.flash_high_bytes);
    try j.field("sdram_high_water_bytes", rows[0].result.sdram_high_bytes);
    try j.field("headroom_percent", sweep.headroom_percent);
    try j.field("flash_min_bytes", summary.flash_min_bytes);
    try j.field("sdram_min_bytes", summary.sdram_min_bytes);
    try j.field("fastest_config", summary.fastest);
    try j.field("slowest_config_meeting_target", if (target_ns == null) null else summary.slowest_meeting);
    try j.close('}');
    try j.open("configs", '[');
    for (rows, 0..) |row, index| try config(&j, index, row, source == .elf);
    try j.close(']');
    try j.close('}');
    try out.writeByte('\n');
}

fn describe(j: anytype, source: Source) !void {
    try j.open("workload", '{');
    const job = switch (source) {
        .synthetic => |synthetic| synthetic,
        .elf => |path| {
            try j.field("kind", "guest_image");
            try j.field("elf", path);
            return j.close('}');
        },
    };
    try j.field("kind", "synthetic_weight_streaming");
    try j.field("weights_bytes", job.weights_bytes);
    try j.field("activations_bytes", job.activations_bytes);
    try j.field("passes", job.passes);
    try j.field("chunk_bytes", job.chunk_bytes);
    try j.field("npu_hz", job.npu_hz);
    try j.field("npu_macs_per_cycle", job.npu_macs_per_cycle);
    try j.field("macs_per_weight_byte", job.macs_per_weight_byte);
    try j.field("cpu_hz", job.cpu_hz);
    try j.field("cpu_cycles_per_pass", job.cpu_cycles_per_pass);
    try j.close('}');
}

fn config(j: anytype, index: usize, row: sweep.Row, guest: bool) !void {
    const result = row.result;
    try j.open(null, '{');
    try j.field("index", index);
    try j.field("ospi_width_bits", row.config.ospi.width);
    try j.field("ospi_clock_hz", row.config.ospi.clock_hz);
    try j.field("ospi_latency_cycles", row.config.ospi.latency_cycles);
    try j.field("sdram_width_bits", row.config.sdram.width);
    try j.field("sdram_clock_hz", row.config.sdram.clock_hz);
    try j.field("sdram_cas_latency", row.config.sdram.latency_cycles);
    try j.field("total_ns", result.total_ns);
    try j.field("npu_compute_ns", if (guest) null else result.npu_ns);
    try j.field("cpu_compute_ns", if (guest) null else result.cpu_ns);
    try j.field("memory_stall_ns", result.stall_ns);
    try j.field("flash_bytes_read", result.flash_bytes_read);
    try j.field("sdram_bytes_moved", result.sdram_bytes_moved);
    try j.field("meets_target", row.meets);
    try j.close('}');
}
