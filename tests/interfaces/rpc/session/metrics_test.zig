//! Tests for src/interfaces/rpc/session/metrics.zig and metrics_wire.zig (RA8EMU-1241).
const std = @import("std");
const ra8 = @import("ra8");

const proto = ra8.rpc.session.rpc;
const server = ra8.rpc.session.server;
const metrics = server.session_metrics;
const device_metrics = ra8.session.device_metrics;
const host_metrics = ra8.host.metrics;

const image = "tests/fixtures/fpu/fp_basic.elf";

test "MetricsReport wire layout and codec roundtrip" {
    const report: proto.MetricsReport = .{
        .host_cpu_percent = 45,
        .host_rss_mb = 128,
        .host_threads = 16,
        .cpu0_load_percent = 82,
        .cpu0_pinned = 1,
        .cpu0_ram_used_bytes = 65536,
        .cpu0_ram_total_bytes = 2097152,
        .cpu1_load_percent = 15,
        .cpu1_pinned = 0,
        .cpu1_ram_used_bytes = 16384,
        .cpu1_ram_total_bytes = 2097152,
    };

    var buf: [64]u8 = undefined;
    const encoded = try proto.encode(proto.MetricsReport, report, &buf);
    try std.testing.expectEqual(@as(usize, 32), encoded.len);

    const decoded = try proto.decode(proto.MetricsReport, encoded);
    try std.testing.expectEqual(report.host_cpu_percent, decoded.host_cpu_percent);
    try std.testing.expectEqual(report.host_rss_mb, decoded.host_rss_mb);
    try std.testing.expectEqual(report.host_threads, decoded.host_threads);
    try std.testing.expectEqual(report.cpu0_load_percent, decoded.cpu0_load_percent);
    try std.testing.expectEqual(report.cpu0_pinned, decoded.cpu0_pinned);
    try std.testing.expectEqual(report.cpu0_ram_used_bytes, decoded.cpu0_ram_used_bytes);
    try std.testing.expectEqual(report.cpu0_ram_total_bytes, decoded.cpu0_ram_total_bytes);
    try std.testing.expectEqual(report.cpu1_load_percent, decoded.cpu1_load_percent);
    try std.testing.expectEqual(report.cpu1_pinned, decoded.cpu1_pinned);
    try std.testing.expectEqual(report.cpu1_ram_used_bytes, decoded.cpu1_ram_used_bytes);
    try std.testing.expectEqual(report.cpu1_ram_total_bytes, decoded.cpu1_ram_total_bytes);
}

test "Method opcode metrics is 0x012E and present in route table" {
    try std.testing.expectEqual(@as(u16, 0x012E), @backingInt(proto.Method.metrics));

    var found = false;
    inline for (server.routes) |route| {
        if (route[0] == @backingInt(proto.Method.metrics)) {
            found = true;
        }
    }
    try std.testing.expect(found);
}

test "sampleCore calculates unattached, load percent, pinned, and ram capacity" {
    var w0: device_metrics.Window = .{};
    const snap_unattached: device_metrics.Snapshot = .{ .attached = false };
    const m_unattached = metrics.sampleCore(&snap_unattached, &w0);
    try std.testing.expectEqual(@as(u8, 0), m_unattached.load_percent);
    try std.testing.expectEqual(@as(u8, 0), m_unattached.pinned);
    try std.testing.expectEqual(@as(u32, 0), m_unattached.ram_used_bytes);
    try std.testing.expectEqual(@as(u32, 0), m_unattached.ram_total_bytes);

    var w1: device_metrics.Window = .{};
    const snap_attached: device_metrics.Snapshot = .{
        .attached = true,
        .active = 750,
        .idle = 250,
        .sram = .{ .pages = 10, .capacity = 2097152, .known = true },
        .sdram = .{ .pages = 2, .capacity = 1048576, .known = true },
    };
    const m_attached = metrics.sampleCore(&snap_attached, &w1);
    try std.testing.expectEqual(@as(u8, 75), m_attached.load_percent);
    try std.testing.expectEqual(@as(u8, 0), m_attached.pinned);
    try std.testing.expectEqual(@as(u32, 12 * 4096), m_attached.ram_used_bytes);
    try std.testing.expectEqual(@as(u32, 2097152 + 1048576), m_attached.ram_total_bytes);

    var w2: device_metrics.Window = .{};
    const snap_pinned: device_metrics.Snapshot = .{
        .attached = true,
        .active = 1000,
        .idle = 0,
    };
    const m_pinned = metrics.sampleCore(&snap_pinned, &w2);
    try std.testing.expectEqual(@as(u8, 100), m_pinned.load_percent);
    try std.testing.expectEqual(@as(u8, 1), m_pinned.pinned);
}

test "sampleHost handles recorded and unavailable telemetry" {
    var sampler: host_metrics.Sampler = .{};
    const raw: host_metrics.Raw = .{
        .cpu_ns = 500_000_000,
        .cores = 4,
        .rss = 200 * 1024 * 1024,
        .threads = 14,
    };
    sampler.record(raw, 1_000_000_000);

    const raw2: host_metrics.Raw = .{
        .cpu_ns = 800_000_000,
        .cores = 4,
        .rss = 220 * 1024 * 1024,
        .threads = 16,
    };
    sampler.record(raw2, 1_500_000_000);

    const host = metrics.sampleHost(&sampler);
    try std.testing.expectEqual(@as(u32, 60), host.cpu_percent);
    try std.testing.expectEqual(@as(u32, 220), host.rss_mb);
    try std.testing.expectEqual(@as(u32, 16), host.threads);

    var empty_sampler: host_metrics.Sampler = .{};
    const empty_host = metrics.sampleHost(&empty_sampler);
    try std.testing.expectEqual(@as(u32, 0), empty_host.cpu_percent);
    try std.testing.expectEqual(@as(u32, 0), empty_host.rss_mb);
    try std.testing.expectEqual(@as(u32, 0), empty_host.threads);
}

test "createReport synthesizes host and dual-core metrics" {
    var sampler: host_metrics.Sampler = .{};
    sampler.record(.{ .rss = 64 * 1024 * 1024, .threads = 6 }, 1_000_000);

    const s0: device_metrics.Snapshot = .{
        .attached = true,
        .active = 80,
        .idle = 20,
        .sram = .{ .pages = 8, .capacity = 1048576, .known = true },
    };
    const s1: device_metrics.Snapshot = .{
        .attached = true,
        .active = 50,
        .idle = 50,
        .sram = .{ .pages = 4, .capacity = 1048576, .known = true },
    };

    var w0: device_metrics.Window = .{};
    var w1: device_metrics.Window = .{};

    const report = metrics.createReport(&sampler, &s0, &w0, &s1, &w1);
    try std.testing.expectEqual(@as(u32, 64), report.host_rss_mb);
    try std.testing.expectEqual(@as(u32, 6), report.host_threads);
    try std.testing.expectEqual(@as(u8, 80), report.cpu0_load_percent);
    try std.testing.expectEqual(@as(u8, 50), report.cpu1_load_percent);
    try std.testing.expectEqual(@as(u32, 8 * 4096), report.cpu0_ram_used_bytes);
    try std.testing.expectEqual(@as(u32, 4 * 4096), report.cpu1_ram_used_bytes);
}

test "metrics RPC handler responds successfully on session harness" {
    var opened = try ra8.session.harness.open(std.testing.allocator, std.testing.io, .{ .elf_path = image });
    defer opened.deinit();

    var scratch: [64]u8 = undefined;
    var context: server.Context = .{ .session = opened.session(), .scratch = &scratch };

    metrics.resetState();
    const outcome = metrics.metrics(&context, .{ .core = .cpu0 });
    const report = switch (outcome) {
        .ok => |r| r,
        .err => return error.TestUnexpectedResult,
    };

    try std.testing.expect(report.cpu0_ram_total_bytes > 0);
    _ = report.host_cpu_percent;
    _ = report.host_rss_mb;
    _ = report.host_threads;
}

test "MetricsReport boundary values wire roundtrip and exact 32 bytes size" {
    const boundary_report: proto.MetricsReport = .{
        .host_cpu_percent = std.math.maxInt(u32),
        .host_rss_mb = 4096,
        .host_threads = 1024,
        .cpu0_load_percent = 100,
        .cpu0_pinned = 1,
        .cpu0_ram_used_bytes = 4 * 1024 * 1024 * 1024 - 1,
        .cpu0_ram_total_bytes = std.math.maxInt(u32),
        .cpu1_load_percent = 100,
        .cpu1_pinned = 1,
        .cpu1_ram_used_bytes = 4 * 1024 * 1024 * 1024 - 1,
        .cpu1_ram_total_bytes = std.math.maxInt(u32),
    };

    var buf: [64]u8 = undefined;
    const encoded = try proto.encode(proto.MetricsReport, boundary_report, &buf);
    try std.testing.expectEqual(@as(usize, 32), encoded.len);

    const decoded = try proto.decode(proto.MetricsReport, encoded);
    try std.testing.expectEqual(boundary_report.host_cpu_percent, decoded.host_cpu_percent);
    try std.testing.expectEqual(boundary_report.host_rss_mb, decoded.host_rss_mb);
    try std.testing.expectEqual(boundary_report.host_threads, decoded.host_threads);
    try std.testing.expectEqual(boundary_report.cpu0_load_percent, decoded.cpu0_load_percent);
    try std.testing.expectEqual(boundary_report.cpu0_pinned, decoded.cpu0_pinned);
    try std.testing.expectEqual(boundary_report.cpu0_ram_used_bytes, decoded.cpu0_ram_used_bytes);
    try std.testing.expectEqual(boundary_report.cpu0_ram_total_bytes, decoded.cpu0_ram_total_bytes);
    try std.testing.expectEqual(boundary_report.cpu1_load_percent, decoded.cpu1_load_percent);
    try std.testing.expectEqual(boundary_report.cpu1_pinned, decoded.cpu1_pinned);
    try std.testing.expectEqual(boundary_report.cpu1_ram_used_bytes, decoded.cpu1_ram_used_bytes);
    try std.testing.expectEqual(boundary_report.cpu1_ram_total_bytes, decoded.cpu1_ram_total_bytes);

    const zero_report: proto.MetricsReport = .{};
    const zero_encoded = try proto.encode(proto.MetricsReport, zero_report, &buf);
    try std.testing.expectEqual(@as(usize, 32), zero_encoded.len);
    for (zero_encoded) |byte| {
        try std.testing.expectEqual(@as(u8, 0), byte);
    }
    const zero_decoded = try proto.decode(proto.MetricsReport, zero_encoded);
    try std.testing.expectEqual(@as(u32, 0), zero_decoded.host_cpu_percent);
    try std.testing.expectEqual(@as(u32, 0), zero_decoded.cpu0_ram_total_bytes);
}

test "MetricsReport codec strictly rejects under-read and over-read" {
    const valid: proto.MetricsReport = .{ .host_cpu_percent = 50, .cpu0_load_percent = 25 };
    var buf: [64]u8 = undefined;
    const encoded = try proto.encode(proto.MetricsReport, valid, &buf);
    try std.testing.expectEqual(@as(usize, 32), encoded.len);

    // Under-reads must fail with Truncated
    try std.testing.expectError(error.Truncated, proto.decode(proto.MetricsReport, encoded[0..0]));
    try std.testing.expectError(error.Truncated, proto.decode(proto.MetricsReport, encoded[0..1]));
    try std.testing.expectError(error.Truncated, proto.decode(proto.MetricsReport, encoded[0..16]));
    try std.testing.expectError(error.Truncated, proto.decode(proto.MetricsReport, encoded[0..31]));

    // Over-reads must fail with Trailing
    var over_buf: [48]u8 = undefined;
    @memcpy(over_buf[0..32], encoded);
    @memset(over_buf[32..48], 0xFF);
    try std.testing.expectError(error.Trailing, proto.decode(proto.MetricsReport, over_buf[0..33]));
    try std.testing.expectError(error.Trailing, proto.decode(proto.MetricsReport, over_buf[0..40]));
    try std.testing.expectError(error.Trailing, proto.decode(proto.MetricsReport, over_buf[0..48]));

    // Exact length must succeed
    const ok = try proto.decode(proto.MetricsReport, encoded[0..32]);
    try std.testing.expectEqual(@as(u32, 50), ok.host_cpu_percent);
    try std.testing.expectEqual(@as(u8, 25), ok.cpu0_load_percent);
}

test "rapid repeated RPC queries stress test (10,000 iterations)" {
    var opened = try ra8.session.harness.open(std.testing.allocator, std.testing.io, .{ .elf_path = image });
    defer opened.deinit();

    var scratch: [64]u8 = undefined;
    var context: server.Context = .{ .session = opened.session(), .scratch = &scratch };
    metrics.resetState();

    var encode_buf: [64]u8 = undefined;
    var i: usize = 0;
    while (i < 10000) : (i += 1) {
        const outcome = metrics.metrics(&context, .{ .core = .cpu0 });
        const report = switch (outcome) {
            .ok => |r| r,
            .err => return error.TestUnexpectedResult,
        };
        const wire_slice = try proto.encode(proto.MetricsReport, report, &encode_buf);
        try std.testing.expectEqual(@as(usize, 32), wire_slice.len);
        const decoded = try proto.decode(proto.MetricsReport, wire_slice);
        try std.testing.expectEqual(report.cpu0_ram_total_bytes, decoded.cpu0_ram_total_bytes);
    }
}

test "sampleCore stress: boundary load, zero active/idle, pinned transitions, and RAM clamping" {
    var w: device_metrics.Window = .{};

    // Both active and idle 0
    const zero_snap: device_metrics.Snapshot = .{ .attached = true, .active = 0, .idle = 0 };
    const zero_metrics = metrics.sampleCore(&zero_snap, &w);
    try std.testing.expectEqual(@as(u8, 0), zero_metrics.load_percent);
    try std.testing.expectEqual(@as(u8, 0), zero_metrics.pinned);

    // 100% active, 0 idle -> pinned
    const pinned_snap: device_metrics.Snapshot = .{ .attached = true, .active = 10_000, .idle = 0 };
    const pinned_metrics = metrics.sampleCore(&pinned_snap, &w);
    try std.testing.expectEqual(@as(u8, 100), pinned_metrics.load_percent);
    try std.testing.expectEqual(@as(u8, 1), pinned_metrics.pinned);

    // Large RAM pages and capacity clamping (within usize without overflow)
    const large_ram_snap: device_metrics.Snapshot = .{
        .attached = true,
        .active = 500,
        .idle = 500,
        .sram = .{ .pages = 1_000_000, .capacity = 2 * 1024 * 1024 * 1024, .known = true },
        .sdram = .{ .pages = 1_000_000, .capacity = 3 * 1024 * 1024 * 1024, .known = true },
    };
    var w2: device_metrics.Window = .{};
    const large_metrics = metrics.sampleCore(&large_ram_snap, &w2);
    try std.testing.expectEqual(std.math.maxInt(u32), large_metrics.ram_used_bytes);
    try std.testing.expectEqual(std.math.maxInt(u32), large_metrics.ram_total_bytes);
}

test "sampleCore ram_used calculation must saturate without integer overflow" {
    var w: device_metrics.Window = .{};
    const huge_pages_snap: device_metrics.Snapshot = .{
        .attached = true,
        .active = 100,
        .idle = 100,
        .sram = .{ .pages = std.math.maxInt(usize) / 2, .capacity = 1024, .known = true },
        .sdram = .{ .pages = 10, .capacity = 1024, .known = true },
    };
    const res = metrics.sampleCore(&huge_pages_snap, &w);
    try std.testing.expectEqual(std.math.maxInt(u32), res.ram_used_bytes);
}

test "sampleCore capacity sum must saturate without integer overflow" {
    var w: device_metrics.Window = .{};
    const huge_ram_snap: device_metrics.Snapshot = .{
        .attached = true,
        .active = 100,
        .idle = 100,
        .sram = .{ .pages = 10, .capacity = std.math.maxInt(usize), .known = true },
        .sdram = .{ .pages = 10, .capacity = 1, .known = true },
    };
    const res = metrics.sampleCore(&huge_ram_snap, &w);
    try std.testing.expectEqual(std.math.maxInt(u32), res.ram_total_bytes);
}

test "sampleCore active + idle sum must not overflow u64" {
    var w: device_metrics.Window = .{};
    const overflow_cycles_snap: device_metrics.Snapshot = .{
        .attached = true,
        .epoch = 1,
        .active = std.math.maxInt(u64),
        .idle = 100,
    };
    const res = metrics.sampleCore(&overflow_cycles_snap, &w);
    try std.testing.expect(res.load_percent <= 100);
}

test "sampleHost float conversion must not panic on out of bounds floats" {
    var sampler: host_metrics.Sampler = .{};
    sampler.current = .{ .cpu_percent = std.math.nan(f64), .rss = 1024, .threads = 2 };
    const host_nan = metrics.sampleHost(&sampler);
    try std.testing.expectEqual(@as(u32, 0), host_nan.cpu_percent);

    sampler.current = .{ .cpu_percent = -50.0, .rss = 1024, .threads = 2 };
    try std.testing.expectEqual(@as(u32, 0), metrics.sampleHost(&sampler).cpu_percent);

    sampler.current = .{ .cpu_percent = -std.math.inf(f64), .rss = 1024, .threads = 2 };
    try std.testing.expectEqual(@as(u32, 0), metrics.sampleHost(&sampler).cpu_percent);

    sampler.current = .{ .cpu_percent = std.math.inf(f64), .rss = 1024, .threads = 2 };
    try std.testing.expectEqual(std.math.maxInt(u32), metrics.sampleHost(&sampler).cpu_percent);

    sampler.current = .{ .cpu_percent = 1e25, .rss = 1024, .threads = 2 };
    const res = metrics.sampleHost(&sampler);
    try std.testing.expectEqual(std.math.maxInt(u32), res.cpu_percent);
}

test "sampleHost stress: boundary CPU percent, 4GB RSS, and 1024 threads" {
    var sampler: host_metrics.Sampler = .{};
    sampler.record(.{
        .cpu_ns = 800_000_000,
        .cores = 8,
        .rss = 4 * 1024 * 1024 * 1024,
        .threads = 1024,
    }, 1_000_000_000);

    sampler.record(.{
        .cpu_ns = 4_800_000_000,
        .cores = 8,
        .rss = 4 * 1024 * 1024 * 1024,
        .threads = 1024,
    }, 1_500_000_000);

    const host = metrics.sampleHost(&sampler);
    // 4s cpu in 0.5s wall time across 8 cores = 800%
    try std.testing.expectEqual(@as(u32, 800), host.cpu_percent);
    try std.testing.expectEqual(@as(u32, 4096), host.rss_mb);
    try std.testing.expectEqual(@as(u32, 1024), host.threads);
}
