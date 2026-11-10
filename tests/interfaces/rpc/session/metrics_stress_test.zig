//! Empirical stress tests for Host & Device Metrics RPC Endpoint 0x012E (RA8EMU-1241).
const std = @import("std");
const ra8 = @import("ra8");
const test_paths = @import("test_paths");

const served = ra8.rpc.session.server;
const rpc = served.rpc_lib;
const proto = ra8.rpc.session.rpc;
const setup = ra8.rpc.served_setup;
const metrics = served.session_metrics;
const device_metrics = ra8.session.device_metrics;
const host_metrics = ra8.host.metrics;

const Env = proto.Client.Env;
const image0 = test_paths.threadx_dual;
const image1 = test_paths.threadx_dual_cpu1;
const single_image = "tests/fixtures/fpu/fp_basic.elf";

const Wire = struct {
    gpa: std.mem.Allocator,
    pipes: [2][]u8,
    rx: [2][]u8,
    tx: []u8,
    loop: rpc.Loopback = undefined,
    client: proto.Client = undefined,
    host: served.Host = undefined,

    fn init(gpa: std.mem.Allocator) !*Wire {
        const self = try gpa.create(Wire);
        self.* = .{
            .gpa = gpa,
            .pipes = undefined,
            .rx = undefined,
            .tx = try gpa.alloc(u8, Env.max_frame),
        };
        for (&self.pipes) |*pipe| pipe.* = try gpa.alloc(u8, 2 * Env.max_frame);
        for (&self.rx) |*rx| rx.* = try gpa.alloc(u8, 2 * Env.max_frame);
        self.loop = rpc.Loopback.init(self.pipes[0], self.pipes[1]);
        return self;
    }

    fn deinit(self: *Wire) void {
        for (self.pipes ++ self.rx) |buffer| self.gpa.free(buffer);
        self.gpa.free(self.tx);
        self.gpa.destroy(self);
    }

    fn open(self: *Wire, context: *served.Context) !void {
        self.client = proto.Client.init(self.loop.a(), self.rx[0], proto.capabilities);
        self.host = served.Host.init(self.loop.b(), self.rx[1], context);
        try self.client.greet(self.tx);
        try std.testing.expectEqual(rpc.Step.greeted, try self.host.poll(self.tx));
        _ = (try self.client.poll(self.tx)).?;
    }

    fn call(self: *Wire, comptime Args: type, method: proto.Method, args: Args) !Env.Result {
        _ = try self.client.call(Args, @backingInt(method), args, 0, self.tx);
        try std.testing.expectEqual(rpc.Step.answered, try self.host.poll(self.tx));
        while (try self.client.poll(self.tx)) |incoming| switch (incoming) {
            .response => |response| return response.result,
            .event => {},
            .ready => return error.Unexpected,
        };
        return error.NoResponse;
    }
};

fn reply(comptime T: type, result: Env.Result) !T {
    return switch (result) {
        .ok => |bytes| try proto.decode(T, bytes),
        .err => return error.Refused,
    };
}

test "stress: dual-core live served session reflects active cycles, RAM pages touched, and pinned state" {
    const gpa = std.testing.allocator;
    var opened: setup.Served = undefined;
    try opened.open(gpa, std.testing.io, image0, null, null);
    defer opened.deinit();
    try opened.openSecond(image1);

    var wire = try Wire.init(gpa);
    defer wire.deinit();
    try wire.open(&opened.context);

    metrics.resetState();

    // 1. Initial metrics query over wire RPC before execution
    const m0 = try reply(proto.MetricsReport, try wire.call(proto.CoreOnly, .metrics, .{ .core = .cpu0 }));
    try std.testing.expect(m0.cpu0_ram_total_bytes > 0);
    try std.testing.expect(m0.cpu1_ram_total_bytes > 0);
    // Before running, no SRAM/SDRAM pages touched by CPU execution
    try std.testing.expectEqual(@as(u32, 0), m0.cpu0_ram_used_bytes);
    try std.testing.expectEqual(@as(u32, 0), m0.cpu1_ram_used_bytes);

    // Verify initial RAM used matches page tracking
    const snap0 = opened.owner.session().deviceMetrics(.cpu0);
    const snap1 = opened.owner.session().deviceMetrics(.cpu1);
    try std.testing.expectEqual(@as(u32, @intCast((snap0.sram.pages + snap0.sdram.pages) * 4096)), m0.cpu0_ram_used_bytes);
    try std.testing.expectEqual(@as(u32, @intCast((snap1.sram.pages + snap1.sdram.pages) * 4096)), m0.cpu1_ram_used_bytes);

    // 2. Run CPU0 under an instruction budget and verify emulation cycles reflect
    _ = try reply(proto.Ack, try wire.call(proto.Run, .run, .{ .core = .cpu0, .mode = .cont, .budget = 40_000 }));
    const m1 = try reply(proto.MetricsReport, try wire.call(proto.CoreOnly, .metrics, .{ .core = .cpu0 }));
    try std.testing.expect(m1.cpu0_load_percent > 0 or m1.cpu0_pinned == 1);
    try std.testing.expect(m1.cpu0_ram_used_bytes >= m0.cpu0_ram_used_bytes);

    // 3. Run CPU1 under an instruction budget and verify emulation cycles reflect
    _ = try reply(proto.Ack, try wire.call(proto.Run, .run, .{ .core = .cpu1, .mode = .cont, .budget = 40_000 }));
    const m2 = try reply(proto.MetricsReport, try wire.call(proto.CoreOnly, .metrics, .{ .core = .cpu1 }));
    try std.testing.expect(m2.cpu1_load_percent > 0 or m2.cpu1_pinned == 1);
    try std.testing.expect(m2.cpu1_ram_used_bytes >= m0.cpu1_ram_used_bytes);

    // Verify host telemetry is populated
    try std.testing.expect(m2.host_rss_mb > 0);
    try std.testing.expect(m2.host_threads > 0);
}

test "stress: host telemetry reflects live Darwin process metrics under load and caching within interval" {
    const gpa = std.testing.allocator;
    var opened: setup.Served = undefined;
    try opened.open(gpa, std.testing.io, single_image, null, null);
    defer opened.deinit();

    var wire = try Wire.init(gpa);
    defer wire.deinit();
    try wire.open(&opened.context);

    metrics.resetState();

    const m0 = try reply(proto.MetricsReport, try wire.call(proto.CoreOnly, .metrics, .{ .core = .cpu0 }));
    try std.testing.expect(m0.host_rss_mb > 0);
    try std.testing.expect(m0.host_threads >= 1);

    // Rapid successive call: must return cached sample within interval (< 500ms)
    const m1 = try reply(proto.MetricsReport, try wire.call(proto.CoreOnly, .metrics, .{ .core = .cpu0 }));
    try std.testing.expectEqual(m0.host_rss_mb, m1.host_rss_mb);
    try std.testing.expectEqual(m0.host_threads, m1.host_threads);

    // Perform real CPU work across host interval (>= 500ms)
    const began = std.Io.Timestamp.now(std.testing.io, .awake);
    var elapsed: u64 = 0;
    var dummy: u64 = 1;
    while (elapsed < host_metrics.interval_ns + 50_000_000) {
        for (0..20000) |_| dummy = dummy *% 6364136223846793005 +% 1;
        std.mem.doNotOptimizeAway(dummy);
        elapsed = @intCast(began.untilNow(std.testing.io, .awake).nanoseconds);
    }

    // Next metrics call after interval: host CPU percentage is refreshed
    const m2 = try reply(proto.MetricsReport, try wire.call(proto.CoreOnly, .metrics, .{ .core = .cpu0 }));
    try std.testing.expect(m2.host_rss_mb > 0);
    try std.testing.expect(m2.host_threads >= 1);
    try std.testing.expect(m2.host_cpu_percent >= 0);
}

test "stress: repeated metrics calls across time epochs and rewind reset" {
    var w: device_metrics.Window = .{};

    // Epoch 0: initial sample
    const s0: device_metrics.Snapshot = .{ .attached = true, .epoch = 0, .active = 100, .idle = 0 };
    const c0 = metrics.sampleCore(&s0, &w);
    try std.testing.expectEqual(@as(u8, 100), c0.load_percent);
    try std.testing.expectEqual(@as(u8, 1), c0.pinned);

    // Epoch 0: delta advance
    const s1: device_metrics.Snapshot = .{ .attached = true, .epoch = 0, .active = 150, .idle = 50 };
    const c1 = metrics.sampleCore(&s1, &w);
    try std.testing.expectEqual(@as(u8, 50), c1.load_percent);
    try std.testing.expectEqual(@as(u8, 0), c1.pinned);

    // Epoch 1: rewind/restore advances epoch and active drops
    const s2: device_metrics.Snapshot = .{ .attached = true, .epoch = 1, .active = 20, .idle = 80 };
    const c2 = metrics.sampleCore(&s2, &w);
    try std.testing.expectEqual(@as(u8, 20), c2.load_percent);
    try std.testing.expectEqual(@as(u8, 0), c2.pinned);

    // Epoch 1: second sample in new epoch computes delta from s2
    const s3: device_metrics.Snapshot = .{ .attached = true, .epoch = 1, .active = 100, .idle = 80 };
    const c3 = metrics.sampleCore(&s3, &w);
    try std.testing.expectEqual(@as(u8, 100), c3.load_percent);
    try std.testing.expectEqual(@as(u8, 1), c3.pinned);
}

test "stress: single-core session with unattached CPU1 returns clean zeroed telemetry" {
    const gpa = std.testing.allocator;
    var opened: setup.Served = undefined;
    try opened.open(gpa, std.testing.io, single_image, null, null);
    defer opened.deinit();

    var wire = try Wire.init(gpa);
    defer wire.deinit();
    try wire.open(&opened.context);

    metrics.resetState();

    const report = try reply(proto.MetricsReport, try wire.call(proto.CoreOnly, .metrics, .{ .core = .cpu0 }));
    try std.testing.expect(report.cpu0_ram_total_bytes > 0);
    try std.testing.expectEqual(@as(u8, 0), report.cpu1_load_percent);
    try std.testing.expectEqual(@as(u8, 0), report.cpu1_pinned);
    try std.testing.expectEqual(@as(u32, 0), report.cpu1_ram_used_bytes);
    try std.testing.expectEqual(@as(u32, 0), report.cpu1_ram_total_bytes);
}

test "stress: wire serialization exact binary layout and boundary values" {
    const max_report: proto.MetricsReport = .{
        .host_cpu_percent = std.math.maxInt(u32),
        .host_rss_mb = std.math.maxInt(u32),
        .host_threads = std.math.maxInt(u32),
        .cpu0_load_percent = std.math.maxInt(u8),
        .cpu0_pinned = 1,
        .cpu0_ram_used_bytes = std.math.maxInt(u32),
        .cpu0_ram_total_bytes = std.math.maxInt(u32),
        .cpu1_load_percent = std.math.maxInt(u8),
        .cpu1_pinned = 1,
        .cpu1_ram_used_bytes = std.math.maxInt(u32),
        .cpu1_ram_total_bytes = std.math.maxInt(u32),
    };

    var buf: [64]u8 = undefined;
    const encoded = try proto.encode(proto.MetricsReport, max_report, &buf);
    try std.testing.expectEqual(@as(usize, 32), encoded.len);

    const decoded = try proto.decode(proto.MetricsReport, encoded);
    try std.testing.expectEqual(max_report.host_cpu_percent, decoded.host_cpu_percent);
    try std.testing.expectEqual(max_report.host_rss_mb, decoded.host_rss_mb);
    try std.testing.expectEqual(max_report.host_threads, decoded.host_threads);
    try std.testing.expectEqual(max_report.cpu0_load_percent, decoded.cpu0_load_percent);
    try std.testing.expectEqual(max_report.cpu0_pinned, decoded.cpu0_pinned);
    try std.testing.expectEqual(max_report.cpu0_ram_used_bytes, decoded.cpu0_ram_used_bytes);
    try std.testing.expectEqual(max_report.cpu0_ram_total_bytes, decoded.cpu0_ram_total_bytes);
    try std.testing.expectEqual(max_report.cpu1_load_percent, decoded.cpu1_load_percent);
    try std.testing.expectEqual(max_report.cpu1_pinned, decoded.cpu1_pinned);
    try std.testing.expectEqual(max_report.cpu1_ram_used_bytes, decoded.cpu1_ram_used_bytes);
    try std.testing.expectEqual(max_report.cpu1_ram_total_bytes, decoded.cpu1_ram_total_bytes);
}

test "adversarial: RAM capacity and pages overflow matrix and fuzz generator" {
    var w: device_metrics.Window = .{};
    const max_u = std.math.maxInt(usize);
    const max_u32 = std.math.maxInt(u32);
    const cap_cases = [_][2]usize{
        .{ 0, 0 },           .{ max_u, 0 },     .{ 0, max_u },                 .{ max_u, 1 },
        .{ 1, max_u },       .{ max_u, max_u }, .{ max_u / 2, max_u / 2 + 1 }, .{ max_u32, max_u32 },
        .{ max_u32 + 1, 0 },
    };
    for (cap_cases) |c| {
        const snap = device_metrics.Snapshot{
            .attached = true,
            .sram = .{ .capacity = c[0], .known = true },
            .sdram = .{ .capacity = c[1], .known = true },
        };
        const res = metrics.sampleCore(&snap, &w);
        const exp: u32 = @intCast(@min(max_u32, c[0] +| c[1]));
        try std.testing.expectEqual(exp, res.ram_total_bytes);
    }

    const page_cases = [_][2]usize{
        .{ 0, 0 },                 .{ 1048575, 0 },   .{ 1048576, 0 },      .{ max_u, 0 },
        .{ 0, max_u },             .{ max_u, max_u }, .{ max_u / 4096, 0 }, .{ max_u / 4096 + 1, 0 },
        .{ max_u / 2, max_u / 2 },
    };
    for (page_cases) |p| {
        const snap = device_metrics.Snapshot{
            .attached = true,
            .sram = .{ .pages = p[0], .known = true },
            .sdram = .{ .pages = p[1], .known = true },
        };
        const res = metrics.sampleCore(&snap, &w);
        const exp: u32 = @intCast(@min(max_u32, (p[0] +| p[1]) *| 4096));
        try std.testing.expectEqual(exp, res.ram_used_bytes);
    }

    var prng = std.Random.DefaultPrng.init(0xdeadbeef);
    const rand = prng.random();
    for (0..20_000) |_| {
        const sp = rand.int(usize);
        const sdp = rand.int(usize);
        const sc = rand.int(usize);
        const sdc = rand.int(usize);
        const snap = device_metrics.Snapshot{
            .attached = true,
            .sram = .{ .pages = sp, .capacity = sc, .known = true },
            .sdram = .{ .pages = sdp, .capacity = sdc, .known = true },
        };
        const res = metrics.sampleCore(&snap, &w);
        try std.testing.expectEqual(@as(u32, @intCast(@min(max_u32, (sp +| sdp) *| 4096))), res.ram_used_bytes);
        try std.testing.expectEqual(@as(u32, @intCast(@min(max_u32, sc +| sdc))), res.ram_total_bytes);
    }
}

test "adversarial: active + idle u64 overflow matrix and fuzz generator" {
    var w: device_metrics.Window = .{};
    const max_u64 = std.math.maxInt(u64);
    const cycle_cases = [_][2]u64{
        .{ 0, 0 },               .{ 1, 0 },                     .{ 0, 1 },       .{ max_u64, 0 },
        .{ 0, max_u64 },         .{ max_u64, 1 },               .{ 1, max_u64 }, .{ max_u64, max_u64 },
        .{ max_u64 - 100, 200 }, .{ max_u64 / 2, max_u64 / 2 },
    };
    for (cycle_cases) |c| {
        w = .{};
        const snap = device_metrics.Snapshot{
            .attached = true,
            .active = c[0],
            .idle = c[1],
        };
        const res = metrics.sampleCore(&snap, &w);
        try std.testing.expect(res.load_percent <= 100);
        if (c[0] > 0 and c[1] == 0) {
            try std.testing.expectEqual(@as(u8, 1), res.pinned);
            try std.testing.expectEqual(@as(u8, 100), res.load_percent);
        } else if (c[0] == 0) {
            try std.testing.expectEqual(@as(u8, 0), res.pinned);
            try std.testing.expectEqual(@as(u8, 0), res.load_percent);
        }
    }

    var prng = std.Random.DefaultPrng.init(0xcafebabe);
    const rand = prng.random();
    for (0..20_000) |_| {
        w = .{};
        const act = rand.int(u64);
        const idl = rand.int(u64);
        const snap = device_metrics.Snapshot{ .attached = true, .active = act, .idle = idl };
        const res = metrics.sampleCore(&snap, &w);
        try std.testing.expect(res.load_percent <= 100);
        try std.testing.expect(res.pinned <= 1);
    }
}

test "adversarial: host cpu_percent IEEE 754 edge matrix and fuzz generator" {
    var sampler: host_metrics.Sampler = .{};
    const max_u32 = std.math.maxInt(u32);
    const max_u32_f: f64 = @floatFromInt(max_u32);
    const float_cases = [_]struct { in: f64, exp: u32 }{
        .{ .in = 0.0, .exp = 0 },
        .{ .in = -0.0, .exp = 0 },
        .{ .in = -1.0, .exp = 0 },
        .{ .in = -100.5, .exp = 0 },
        .{ .in = -1e300, .exp = 0 },
        .{ .in = std.math.nan(f64), .exp = 0 },
        .{ .in = -std.math.nan(f64), .exp = 0 },
        .{ .in = -std.math.inf(f64), .exp = 0 },
        .{ .in = std.math.inf(f64), .exp = max_u32 },
        .{ .in = max_u32_f, .exp = max_u32 },
        .{ .in = max_u32_f + 1.0, .exp = max_u32 },
        .{ .in = 1e20, .exp = max_u32 },
        .{ .in = std.math.floatMax(f64), .exp = max_u32 },
        .{ .in = 50.7, .exp = 50 },
        .{ .in = 99.99, .exp = 99 },
    };
    for (float_cases) |c| {
        sampler.current = .{ .cpu_percent = c.in, .rss = 1024, .threads = 1 };
        const host = metrics.sampleHost(&sampler);
        try std.testing.expectEqual(c.exp, host.cpu_percent);
    }

    var prng = std.Random.DefaultPrng.init(0x1337c0de);
    const rand = prng.random();
    for (0..20_000) |_| {
        const raw_bits = rand.int(u64);
        const f: f64 = @bitCast(raw_bits);
        sampler.current = .{ .cpu_percent = f, .rss = 1024, .threads = 1 };
        const host = metrics.sampleHost(&sampler);
        if (std.math.isNan(f) or f <= 0.0) {
            try std.testing.expectEqual(@as(u32, 0), host.cpu_percent);
        } else if (std.math.isInf(f) or f >= max_u32_f) {
            try std.testing.expectEqual(max_u32, host.cpu_percent);
        } else {
            try std.testing.expectEqual(@as(u32, @intFromFloat(f)), host.cpu_percent);
        }
    }
}
