//! Empirical rapid sampling stress tests for Host & Device Metrics (RA8EMU-1241).
const std = @import("std");
const ra8 = @import("ra8");
const test_paths = @import("test_paths");

const served = ra8.rpc.session.server;
const rpc = served.rpc_lib;
const proto = ra8.rpc.session.rpc;
const setup = ra8.rpc.served_setup;
const metrics = served.session_metrics;

const Env = proto.Client.Env;
const image0 = test_paths.threadx_dual;
const image1 = test_paths.threadx_dual_cpu1;

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

test "rapid: live dual-core execution under 1000 rapid metrics samples has zero leaks and zero crashes" {
    const gpa = std.testing.allocator;
    var opened: setup.Served = undefined;
    try opened.open(gpa, std.testing.io, image0, null, null);
    defer opened.deinit();
    try opened.openSecond(image1);

    var wire = try Wire.init(gpa);
    defer wire.deinit();
    try wire.open(&opened.context);

    metrics.resetState();

    for (0..20) |batch| {
        const step_budget: u64 = if (batch % 2 == 0) 100 else 250;
        _ = try reply(proto.Ack, try wire.call(proto.Run, .run, .{ .core = .cpu0, .mode = .cont, .budget = step_budget }));
        _ = try reply(proto.Ack, try wire.call(proto.Run, .run, .{ .core = .cpu1, .mode = .cont, .budget = step_budget }));

        for (0..50) |k| {
            const target_core: proto.Core = if ((batch + k) % 2 == 0) .cpu0 else .cpu1;
            const rep = try reply(proto.MetricsReport, try wire.call(proto.CoreOnly, .metrics, .{ .core = target_core }));
            try std.testing.expect(rep.cpu0_load_percent <= 100);
            try std.testing.expect(rep.cpu1_load_percent <= 100);
            try std.testing.expect(rep.cpu0_pinned <= 1);
            try std.testing.expect(rep.cpu1_pinned <= 1);
            try std.testing.expect(rep.cpu0_ram_total_bytes > 0);
            try std.testing.expect(rep.cpu1_ram_total_bytes > 0);
            try std.testing.expect(rep.host_rss_mb > 0);
            try std.testing.expect(rep.host_threads >= 1);
        }
    }
}

test "rapid: repeated dual-core session lifecycle with metrics produces zero memory leaks" {
    const gpa = std.testing.allocator;
    for (0..3) |_| {
        var opened: setup.Served = undefined;
        try opened.open(gpa, std.testing.io, image0, null, null);
        defer opened.deinit();
        try opened.openSecond(image1);

        var wire = try Wire.init(gpa);
        defer wire.deinit();
        try wire.open(&opened.context);

        metrics.resetState();
        for (0..20) |_| {
            const rep = try reply(proto.MetricsReport, try wire.call(proto.CoreOnly, .metrics, .{ .core = .cpu0 }));
            try std.testing.expect(rep.cpu0_ram_total_bytes > 0);
            try std.testing.expect(rep.cpu1_ram_total_bytes > 0);
        }
    }
}
