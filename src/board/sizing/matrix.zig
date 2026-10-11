//! The board memory configurations a sizing sweep tries (RA8EMU-645). Only
//! the widths, clocks and SDRAM CAS latencies the RA8P1 OSPI and SDRAM
//! controllers take, the limits external_memory.validate holds a board
//! profile to. Each size sits at its controller's ceiling while timing is
//! measured, because timing does not depend on it; the report picks the
//! smallest size that holds the workload afterwards.
const external = @import("../external/memory.zig");

pub const ospi_widths = [_]u8{ 1, 2, 4, 8 };
pub const ospi_clocks = [_]u32{ 41_666_667, 83_333_333, 166_666_667 };
pub const sdram_widths = [_]u8{ 8, 16, 32 };
pub const sdram_clocks = [_]u32{ 66_500_000, 133_000_000 };
pub const sdram_latencies = [_]u8{ 2, 3 };
pub const ospi_max_bytes: u32 = 256 * 1024 * 1024;
pub const sdram_max_bytes: u32 = 128 * 1024 * 1024;

pub const count = ospi_widths.len * ospi_clocks.len * sdram_widths.len * sdram_clocks.len * sdram_latencies.len;

/// Configuration `index`, OSPI width varying fastest and SDRAM CAS latency
/// slowest, so index 0 is the narrowest and slowest of everything.
pub fn at(index: usize) external.Config {
    var rest = index;
    var config: external.Config = .{};
    config.ospi.size = ospi_max_bytes;
    config.ospi.width = pick(u8, &ospi_widths, &rest);
    config.ospi.clock_hz = pick(u32, &ospi_clocks, &rest);
    config.sdram.size = sdram_max_bytes;
    config.sdram.width = pick(u8, &sdram_widths, &rest);
    config.sdram.clock_hz = pick(u32, &sdram_clocks, &rest);
    config.sdram.latency_cycles = pick(u8, &sdram_latencies, &rest);
    return config;
}

fn pick(comptime T: type, values: []const T, rest: *usize) T {
    const value = values[rest.* % values.len];
    rest.* /= values.len;
    return value;
}
