//! Tests for src/interfaces/rpc/session_trace_feed.zig (RA8EMU-832): a
//! served session on a ThreadX image subscribes to the trace topic, runs,
//! and its client receives RTOS events in order and in board time, with
//! thread names matching --trace-rtos-out for the same run.
const std = @import("std");
const ra8 = @import("ra8");

const rpc = ra8.rpc.session_server.rpc_lib;
const api = ra8.session.api;
const proto = ra8.rpc.session_rpc;
const served = ra8.rpc.session_server;
const feed = ra8.rpc.session_trace_feed;
const setup = ra8.rpc.served_setup;
const rtos_names = ra8.session.rtos_names;
const rtos_hook = ra8.session.rtos_hook;

const Env = proto.Client.Env;

const image = "tests/fixtures/threadx/threadx_stkof.elf";

/// One received trace event, its name already checked against the image.
const Got = struct {
    kind: proto.EventKind,
    virtual_ns: u64,
    thread: u32,
    exception: u16,
    named: bool,
};

/// Both ends of one served connection, with buffers off the stack.
const Wire = struct {
    gpa: std.mem.Allocator,
    pipes: [2][]u8,
    rx: [2][]u8,
    tx: []u8,
    loop: rpc.Loopback = undefined,
    client: proto.Client = undefined,
    host: served.Host = undefined,
    opened: ?*setup.Served = null,
    got: std.ArrayListUnmanaged(Got) = .{},

    fn init(gpa: std.mem.Allocator) !*Wire {
        const self = try gpa.create(Wire);
        self.* = .{ .gpa = gpa, .pipes = undefined, .rx = undefined, .tx = try gpa.alloc(u8, Env.max_frame) };
        for (&self.pipes) |*pipe| pipe.* = try gpa.alloc(u8, 2 * Env.max_frame);
        for (&self.rx) |*rx| rx.* = try gpa.alloc(u8, 2 * Env.max_frame);
        self.loop = rpc.Loopback.init(self.pipes[0], self.pipes[1]);
        return self;
    }

    fn deinit(self: *Wire) void {
        for (self.pipes ++ self.rx) |buffer| self.gpa.free(buffer);
        self.gpa.free(self.tx);
        self.got.deinit(self.gpa);
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
        var result: ?Env.Result = null;
        while (try self.client.poll(self.tx)) |incoming| switch (incoming) {
            .response => |response| result = response.result,
            .event => |event| try self.record(event.topic, event.payload),
            .ready => return error.Unexpected,
        };
        return result orelse error.NoResponse;
    }

    fn record(self: *Wire, topic: u16, payload: []const u8) !void {
        try std.testing.expectEqual(@backingInt(proto.Topic.trace), topic);
        const sent = try proto.decode(proto.TraceEvent, payload);
        switch (sent.kind) {
            .rtos_switch, .rtos_idle, .isr_enter, .isr_leave => {},
            else => return error.Unexpected,
        }
        // The name matches what --trace-rtos-out writes for the same thread.
        var want_named = false;
        if (self.opened) |opened| {
            var buffer: [rtos_names.longest]u8 = undefined;
            const memory = rtos_hook.Memory{ .guest = opened.owner.guest() };
            const want = rtos_names.name(memory, sent.thread, &buffer);
            if (want) |found| {
                try std.testing.expectEqualStrings(found, sent.name);
                want_named = found.len > 0;
            } else {
                try std.testing.expectEqualStrings("", sent.name);
            }
        }
        try self.got.append(self.gpa, .{
            .kind = sent.kind,
            .virtual_ns = sent.virtual_ns,
            .thread = sent.thread,
            .exception = sent.exception,
            .named = want_named,
        });
    }
};

fn accepted(result: Env.Result) !void {
    switch (result) {
        .ok => {},
        .err => return error.Refused,
    }
}

test "a served ThreadX image sends RTOS events in order, in board time, with names" {
    const gpa = std.testing.allocator;
    var opened: setup.Served = undefined;
    try opened.open(gpa, std.testing.io, image);
    defer opened.deinit();
    var wire = try Wire.init(gpa);
    defer wire.deinit();
    wire.opened = &opened;
    try wire.open(&opened.context);
    try accepted(try wire.call(proto.Subscription, .subscribe, .{ .core = .cpu0, .topic = .trace }));
    // Run long enough to cross thread switches, then pump the feed.
    try accepted(try wire.call(proto.Advanced, .advance, .{ .core = .cpu0, .ns = 200_000_000 }));
    try accepted(try wire.call(proto.ReadRegister, .read_register, .{ .core = .cpu0, .register = .pc }));
    try std.testing.expect(wire.got.items.len > 0);
    var switches: usize = 0;
    var named: usize = 0;
    var last_ns: u64 = 0;
    for (wire.got.items) |got| {
        try std.testing.expect(got.virtual_ns >= last_ns);
        last_ns = got.virtual_ns;
        if (got.kind == .rtos_switch and got.thread != 0) {
            switches += 1;
            if (got.named) named += 1;
        }
    }
    try std.testing.expect(switches > 0);
    try std.testing.expect(named > 0);
}

test "a served session without the trace hook refuses the trace topic" {
    const gpa = std.testing.allocator;
    var opened: setup.Served = undefined;
    try opened.open(gpa, std.testing.io, image);
    defer opened.deinit();
    opened.context.trace_on = null;
    var wire = try Wire.init(gpa);
    defer wire.deinit();
    try wire.open(&opened.context);
    switch (try wire.call(proto.Subscription, .subscribe, .{ .core = .cpu0, .topic = .trace })) {
        .ok => return error.Unexpected,
        .err => {},
    }
}
