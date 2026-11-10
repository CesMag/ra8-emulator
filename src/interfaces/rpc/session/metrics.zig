//! The metrics request (0x012E, RA8EMU-1241): samples host and guest device telemetry.
const std = @import("std");
const builtin = @import("builtin");
const rpc = @import("ra8_rpc_wire");
const proto = @import("rpc.zig");
const handlers = @import("handlers.zig");
const ra8_host = @import("ra8_host");
const device_metrics = @import("ra8_session").device_metrics;
const api = @import("ra8_session").api;

pub const Outcome = rpc.Outcome(proto.MetricsReport);

var host_sampler: ra8_host.metrics.Sampler = .{};
var cpu0_window: device_metrics.Window = .{};
var cpu1_window: device_metrics.Window = .{};

pub const CoreMetrics = struct {
    load_percent: u8 = 0,
    pinned: u8 = 0,
    ram_used_bytes: u32 = 0,
    ram_total_bytes: u32 = 0,
};

pub const HostTelemetry = struct {
    cpu_percent: u32 = 0,
    rss_mb: u32 = 0,
    threads: u32 = 0,
};

pub fn sampleCore(snap: *const device_metrics.Snapshot, window: *device_metrics.Window) CoreMetrics {
    if (!snap.attached) return .{};
    const was_primed = window.primed;
    const prev_active = window.active;
    const prev_idle = window.idle;
    const prev_epoch = window.epoch;

    window.sample(snap);

    const valid = was_primed and snap.epoch == prev_epoch and snap.active >= prev_active and snap.idle >= prev_idle;
    var load = window.percent;
    var pinned: u8 = if (window.pinned) 1 else 0;
    const total_cycles = @as(u128, snap.active) + snap.idle;
    if (!valid and total_cycles > 0) {
        load = @intCast(@as(u128, snap.active) * 100 / total_cycles);
        pinned = if (snap.active > 0 and snap.idle == 0) 1 else 0;
    }

    const ram_used: u32 = @intCast(@min(std.math.maxInt(u32), (snap.sram.pages +| snap.sdram.pages) *| 4096));
    const ram_total: u32 = @intCast(@min(std.math.maxInt(u32), snap.sram.capacity +| snap.sdram.capacity));

    return .{
        .load_percent = load,
        .pinned = pinned,
        .ram_used_bytes = ram_used,
        .ram_total_bytes = ram_total,
    };
}

pub fn sampleHost(sampler: *const ra8_host.metrics.Sampler) HostTelemetry {
    const sample = sampler.current orelse return .{};
    const raw_cpu = sample.cpu_percent;
    const cpu: u32 = if (std.math.isNan(raw_cpu) or raw_cpu <= 0.0)
        0
    else if (std.math.isInf(raw_cpu) or raw_cpu >= @as(f64, @floatFromInt(std.math.maxInt(u32))))
        std.math.maxInt(u32)
    else
        @intFromFloat(raw_cpu);
    const rss: u32 = @intCast(@min(sample.rss / (1024 * 1024), std.math.maxInt(u32)));
    return .{
        .cpu_percent = cpu,
        .rss_mb = rss,
        .threads = sample.threads,
    };
}

pub fn createReport(
    sampler: *const ra8_host.metrics.Sampler,
    snap0: *const device_metrics.Snapshot,
    w0: *device_metrics.Window,
    snap1: *const device_metrics.Snapshot,
    w1: *device_metrics.Window,
) proto.MetricsReport {
    const host = sampleHost(sampler);
    const c0 = sampleCore(snap0, w0);
    const c1 = sampleCore(snap1, w1);
    return .{
        .host_cpu_percent = host.cpu_percent,
        .host_rss_mb = host.rss_mb,
        .host_threads = host.threads,
        .cpu0_load_percent = c0.load_percent,
        .cpu0_pinned = c0.pinned,
        .cpu0_ram_used_bytes = c0.ram_used_bytes,
        .cpu0_ram_total_bytes = c0.ram_total_bytes,
        .cpu1_load_percent = c1.load_percent,
        .cpu1_pinned = c1.pinned,
        .cpu1_ram_used_bytes = c1.ram_used_bytes,
        .cpu1_ram_total_bytes = c1.ram_total_bytes,
    };
}

fn hostNow(context: *const handlers.Context) u64 {
    if (context.host_clock) |clock| return clock.nowFn(clock.context);
    if (context.wall) |wall| return wall.nowFn(wall.context);
    if (builtin.os.tag != .windows) {
        var ts: std.c.timespec = undefined;
        if (std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts) == 0) {
            return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
        }
    }
    return 0;
}

pub fn metrics(context: *handlers.Context, args: proto.CoreOnly) Outcome {
    _ = args;
    const now_ns = hostNow(context);
    host_sampler.refresh(now_ns);
    const snap0 = context.session.deviceMetrics(.cpu0);
    const snap1 = context.session.deviceMetrics(.cpu1);
    const report = createReport(&host_sampler, &snap0, &cpu0_window, &snap1, &cpu1_window);
    return .{ .ok = report };
}

pub fn resetState() void {
    host_sampler = .{};
    cpu0_window = .{};
    cpu1_window = .{};
}
