//! Flat wire structs for host and guest device telemetry (RA8EMU-1241).

/// Host process health and simulated guest device metrics.
/// All fields are serialized without padding per codec rules.
pub const MetricsReport = struct {
    host_cpu_percent: u32 = 0,
    host_rss_mb: u32 = 0,
    host_threads: u32 = 0,
    cpu0_load_percent: u8 = 0,
    cpu0_pinned: u8 = 0,
    cpu0_ram_used_bytes: u32 = 0,
    cpu0_ram_total_bytes: u32 = 0,
    cpu1_load_percent: u8 = 0,
    cpu1_pinned: u8 = 0,
    cpu1_ram_used_bytes: u32 = 0,
    cpu1_ram_total_bytes: u32 = 0,
};
