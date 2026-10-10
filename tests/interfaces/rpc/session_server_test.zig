//! Host tests for the session RPC route table (RA8EMU-735): a client and a
//! served Session joined over the library's in-memory loopback.
const std = @import("std");
const ra8 = @import("ra8");
const Bounded = ra8.chip.core.bounded.Bounded;
const rpc = served.rpc_lib;
const bus = ra8.chip.core.cpu.bus;
const Cpu = ra8.chip.core.cpu.cpu.Cpu;
const api = ra8.session.session_api;
const Machine = ra8.session.stop_machine.Machine;
const zig_session = ra8.session.step_hook.zig_session;
const timebase = ra8.chip.periph.clocks.timebase;
const proto = ra8.rpc.session_rpc;
const served = ra8.rpc.session_server;

/// Vector table (SP 0x40, reset 0x09) then nop, nop.w, nop at 0x08.
const Ram = struct {
    bytes: [256]u8 = @splat(0),

    fn init() Ram {
        var memory: Ram = .{};
        const code = [_]u8{ 0x40, 0, 0, 0, 0x09, 0, 0, 0, 0x00, 0xBF, 0xAF, 0xF3, 0x00, 0x80, 0x00, 0xBF, 0x80, 0xBA };
        @memcpy(memory.bytes[0..code.len], &code);
        return memory;
    }

    fn view(self: *Ram) bus.Bus {
        return .{ .ctx = self, .vtable = &.{ .read = read, .write = write } };
    }

    fn read(ctx: *anyopaque, address: u32, into: []u8) bus.Error!void {
        const self: *Ram = @ptrCast(@alignCast(ctx));
        if (address + into.len > self.bytes.len) return error.Unmapped;
        @memcpy(into, self.bytes[address..][0..into.len]);
    }

    fn write(ctx: *anyopaque, address: u32, bytes: []const u8) bus.Error!void {
        const self: *Ram = @ptrCast(@alignCast(ctx));
        if (address + bytes.len > self.bytes.len) return error.Unmapped;
        @memcpy(self.bytes[address..][0..bytes.len], bytes);
    }
};

const LoadLog = struct {
    calls: usize = 0,
    last: [16]u8 = undefined,
    len: usize = 0,

    fn load(context: *anyopaque, core: api.Core, image: []const u8) anyerror!void {
        _ = core;
        const self: *LoadLog = @ptrCast(@alignCast(context));
        self.calls += 1;
        self.len = @min(image.len, self.last.len);
        @memcpy(self.last[0..self.len], image[0..self.len]);
    }
};

const Env = proto.Client.Env;

/// Both ends of one served connection, with buffers off the stack.
const Wire = struct {
    gpa: std.mem.Allocator,
    pipes: [2][]u8,
    rx: [2][]u8,
    tx: []u8,
    loop: rpc.Loopback = undefined,
    client: proto.Client = undefined,
    host: served.Host = undefined,
    /// The stop event the last call produced, if any.
    stop: ?proto.Stopped = null,
    /// UART bytes the last call's events carried, and the topics in arrival order.
    uart: Bounded(u8, 64) = .{},
    channels: Bounded(u8, 8) = .{},
    stamps: Bounded(u64, 8) = .{},
    topics: Bounded(proto.Topic, 8) = .{},

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
        self.gpa.destroy(self);
    }

    fn open(self: *Wire, context: *served.Context) !void {
        self.client = proto.Client.init(self.loop.a(), self.rx[0], proto.capabilities);
        self.host = served.Host.init(self.loop.b(), self.rx[1], context);
        try self.client.greet(self.tx);
        try std.testing.expectEqual(rpc.Step.greeted, try self.host.poll(self.tx));
        const ready = (try self.client.poll(self.tx)).?;
        try std.testing.expectEqual(proto.capabilities, ready.ready);
    }

    fn call(self: *Wire, comptime Args: type, method: proto.Method, args: Args) !Env.Result {
        _ = try self.client.call(Args, @backingInt(method), args, 0, self.tx);
        return self.finish();
    }

    fn finish(self: *Wire) !Env.Result {
        try std.testing.expectEqual(rpc.Step.answered, try self.host.poll(self.tx));
        self.stop = null;
        self.uart.len = 0;
        self.channels.len = 0;
        self.stamps.len = 0;
        self.topics.len = 0;
        var result: ?Env.Result = null;
        while (try self.client.poll(self.tx)) |incoming| switch (incoming) {
            .response => |response| result = response.result,
            .event => |event| try self.record(event.topic, event.payload),
            .ready => return error.Unexpected,
        };
        return result orelse error.NoResponse;
    }

    fn record(self: *Wire, topic: u16, payload: []const u8) !void {
        const known: proto.Topic = @fromBackingInt(@intCast(topic));
        try self.topics.append(known);
        switch (known) {
            .stop => self.stop = try proto.decode(proto.Stopped, payload),
            .uart => {
                const sent = try proto.decode(proto.Uart, payload);
                try std.testing.expectEqual(proto.Core.cpu0, sent.core);
                try self.channels.append(sent.channel);
                try self.stamps.append(sent.virtual_ns);
                try self.uart.appendSlice(sent.bytes);
            },
            else => return error.Unexpected,
        }
    }
};

fn reply(comptime T: type, result: Env.Result) !T {
    return switch (result) {
        .ok => |bytes| try proto.decode(T, bytes),
        .err => |code| {
            std.debug.print("refused with {d}\n", .{@backingInt(code)});
            return error.Refused;
        },
    };
}

fn refusal(result: Env.Result) !u16 {
    return switch (result) {
        .ok => error.Accepted,
        .err => |refused| @backingInt(refused),
    };
}

test "a served session loads, runs to a breakpoint, pauses and answers register, memory and time reads" {
    var memory = Ram.init();
    var cpu: Cpu = .{ .bus = memory.view() };
    try cpu.reset(0);
    var machine = Machine{};
    var session: api.Session = .{ .live = .{ .core = .{ .cpu = &cpu }, .machine = &machine, .budget = 100 } };
    var loader: LoadLog = .{};
    session.attachLoader(.{ .context = &loader, .loadFn = LoadLog.load });
    var base: timebase.TimeBase = .{};
    session.attachTimeBase(&base);
    var scratch: [64]u8 = undefined;
    var context: served.Context = .{ .session = &session, .scratch = &scratch };
    const wire = try Wire.init(std.testing.allocator);
    defer wire.deinit();
    try wire.open(&context);

    _ = try reply(proto.Ack, try wire.call(proto.Load, .load, .{ .core = .cpu0, .image = "corpus" }));
    try std.testing.expectEqual(@as(usize, 1), loader.calls);
    try std.testing.expectEqualStrings("corpus", loader.last[0..loader.len]);

    const point = try reply(proto.U32, try wire.call(proto.Point, .set_breakpoint, .{ .core = .cpu0, .address = 0x0E }));
    _ = try reply(proto.Ack, try wire.call(proto.Subscription, .subscribe, .{ .core = .cpu0, .topic = .stop }));
    _ = try reply(proto.Ack, try wire.call(proto.Run, .run, .{ .core = .cpu0, .mode = .run, .budget = 50 }));
    const stopped = wire.stop.?;
    try std.testing.expectEqual(proto.StopReason.breakpoint, stopped.reason);
    try std.testing.expectEqual(@as(u32, 0x0E), stopped.address);
    try std.testing.expectEqual(point.value, stopped.detail);

    _ = try reply(proto.Ack, try wire.call(proto.CoreOnly, .pause, .{ .core = .cpu0 }));
    const pc = try reply(proto.U32, try wire.call(proto.ReadRegister, .read_register, .{ .core = .cpu0, .register = .pc }));
    try std.testing.expectEqual(@as(u32, 0x0E), pc.value);
    _ = try reply(proto.Ack, try wire.call(proto.WriteRegister, .write_register, .{ .core = .cpu0, .register = .r0, .value = 0x1234 }));
    const r0 = try reply(proto.U32, try wire.call(proto.ReadRegister, .read_register, .{ .core = .cpu0, .register = .r0 }));
    try std.testing.expectEqual(@as(u32, 0x1234), r0.value);

    const bytes = try reply(proto.Memory, try wire.call(proto.ReadMemory, .read_memory, .{ .core = .cpu0, .address = 0x08, .length = 2 }));
    try std.testing.expectEqualSlices(u8, &.{ 0x00, 0xBF }, bytes.bytes);
    const time = try reply(proto.U64, try wire.call(proto.Now, .now, .{ .core = .cpu0 }));
    try std.testing.expectEqual(@as(u64, 0), time.value);

    _ = try reply(proto.Ack, try wire.call(proto.PointId, .clear_breakpoint, .{ .core = .cpu0, .id = point.value }));
    _ = try reply(proto.Ack, try wire.call(proto.CoreOnly, .step, .{ .core = .cpu0 }));
    try std.testing.expectEqual(proto.StopReason.stepped, wire.stop.?.reason);
    try std.testing.expectEqual(@as(u32, 0x10), wire.stop.?.address);
}

test "the server refuses unknown methods, missing cores, oversized reads and stale point ids" {
    var memory = Ram.init();
    var cpu: Cpu = .{ .bus = memory.view() };
    try cpu.reset(0);
    var machine = Machine{};
    var session: api.Session = .{ .live = .{ .core = .{ .cpu = &cpu }, .machine = &machine, .budget = 100 } };
    var scratch: [8]u8 = undefined;
    var context: served.Context = .{ .session = &session, .scratch = &scratch };
    const wire = try Wire.init(std.testing.allocator);
    defer wire.deinit();
    try wire.open(&context);

    _ = try wire.client.callBytes(0x0200, &.{}, 0, wire.tx);
    try std.testing.expectEqual(@backingInt(rpc.Code.unknown_method), try refusal(try wire.finish()));
    const missing = try wire.call(proto.ReadRegister, .read_register, .{ .core = .cpu1, .register = .pc });
    try std.testing.expectEqual(served.app_codes.no_core, try refusal(missing));
    const long = try wire.call(proto.ReadMemory, .read_memory, .{ .core = .cpu0, .address = 0, .length = 9 });
    try std.testing.expectEqual(served.app_codes.too_long, try refusal(long));
    const stale = try wire.call(proto.PointId, .remove_point, .{ .core = .cpu0, .id = 7 });
    try std.testing.expectEqual(served.app_codes.refused, try refusal(stale));
    const no_time = try wire.call(proto.Now, .now, .{ .core = .cpu0 });
    try std.testing.expectEqual(served.app_codes.refused, try refusal(no_time));

    _ = try reply(proto.Ack, try wire.call(proto.Run, .run, .{ .core = .cpu0, .mode = .step, .budget = 0 }));
    try std.testing.expect(wire.stop == null);
}

fn sendUart(session: *api.Session, channel: u8, text: []const u8) void {
    sendUartAt(session, channel, text, 0);
}

/// Publishes `text` with byte i stamped `first_ns + i`.
fn sendUartAt(session: *api.Session, channel: u8, text: []const u8, first_ns: u64) void {
    for (text, 0..) |byte, i| session.event_stream.publish(.{ .core = .cpu0, .kind = .uart_byte, .virtual_ns = first_ns + i, .payload = .{ .uart = .{ .channel = channel, .byte = byte } } });
}

test "uart bytes reach a client only while it subscribes, in order and before the stop" {
    var memory = Ram.init();
    var cpu: Cpu = .{ .bus = memory.view() };
    try cpu.reset(0);
    var machine = Machine{};
    var session: api.Session = .{ .live = .{ .core = .{ .cpu = &cpu }, .machine = &machine, .budget = 100 } };
    var scratch: [8]u8 = undefined;
    var context: served.Context = .{ .session = &session, .scratch = &scratch };
    const wire = try Wire.init(std.testing.allocator);
    defer wire.deinit();
    try wire.open(&context);
    const pc: proto.ReadRegister = .{ .core = .cpu0, .register = .pc };

    sendUart(&session, 3, "early");
    _ = try reply(proto.U32, try wire.call(proto.ReadRegister, .read_register, pc));
    try std.testing.expectEqual(@as(usize, 0), wire.uart.len);

    _ = try reply(proto.Ack, try wire.call(proto.Subscription, .subscribe, .{ .core = .cpu0, .topic = .uart }));
    _ = try reply(proto.Ack, try wire.call(proto.Subscription, .subscribe, .{ .core = .cpu0, .topic = .stop }));
    sendUart(&session, 3, "hi");
    sendUart(&session, 4, "!");
    _ = try reply(proto.Ack, try wire.call(proto.Run, .run, .{ .core = .cpu0, .mode = .step, .budget = 0 }));
    try std.testing.expectEqualStrings("hi!", wire.uart.slice());
    try std.testing.expectEqualSlices(u8, &.{ 3, 4 }, wire.channels.slice());
    try std.testing.expectEqualSlices(proto.Topic, &.{ .uart, .uart, .stop }, wire.topics.slice());

    _ = try reply(proto.Ack, try wire.call(proto.Subscription, .unsubscribe, .{ .core = .cpu0, .topic = .uart }));
    try std.testing.expect(context.uart_feed == null);
    sendUart(&session, 3, "late");
    _ = try reply(proto.U32, try wire.call(proto.ReadRegister, .read_register, pc));
    try std.testing.expectEqual(@as(usize, 0), wire.uart.len);
}

test "each uart event carries the virtual time of its run's last byte" {
    var memory = Ram.init();
    var cpu: Cpu = .{ .bus = memory.view() };
    try cpu.reset(0);
    var machine = Machine{};
    var session: api.Session = .{ .live = .{ .core = .{ .cpu = &cpu }, .machine = &machine, .budget = 100 } };
    var scratch: [8]u8 = undefined;
    var context: served.Context = .{ .session = &session, .scratch = &scratch };
    const wire = try Wire.init(std.testing.allocator);
    defer wire.deinit();
    try wire.open(&context);

    _ = try reply(proto.Ack, try wire.call(proto.Subscription, .subscribe, .{ .core = .cpu0, .topic = .uart }));
    sendUartAt(&session, 3, "ab", 100);
    sendUartAt(&session, 4, "c", 200);
    _ = try reply(proto.Ack, try wire.call(proto.Run, .run, .{ .core = .cpu0, .mode = .step, .budget = 0 }));
    try std.testing.expectEqualStrings("abc", wire.uart.slice());
    try std.testing.expectEqualSlices(u64, &.{ 101, 200 }, wire.stamps.slice());
}

test "part methods parse their spec, refuse a bad one and refuse a board with no hooks" {
    var memory = Ram.init();
    var cpu: Cpu = .{ .bus = memory.view() };
    try cpu.reset(0);
    var machine = Machine{};
    var session: api.Session = .{ .live = .{ .core = .{ .cpu = &cpu }, .machine = &machine, .budget = 100 } };
    var scratch: [8]u8 = undefined;
    var context: served.Context = .{ .session = &session, .scratch = &scratch };
    const wire = try Wire.init(std.testing.allocator);
    defer wire.deinit();
    try wire.open(&context);

    const bad = @backingInt(rpc.Code.bad_args);
    const typo = try wire.call(proto.PartSpec, .plug, .{ .core = .cpu0, .text = "nosuch@i2c:riic@0x36" });
    try std.testing.expectEqual(bad, try refusal(typo));
    const no_mode = try wire.call(proto.PartSpec, .set_fault, .{ .core = .cpu0, .text = "@i2c:riic@0x36" });
    try std.testing.expectEqual(bad, try refusal(no_mode));
    const no_endpoint = try wire.call(proto.PartSpec, .unplug, .{ .core = .cpu0, .text = "riic" });
    try std.testing.expectEqual(bad, try refusal(no_endpoint));

    // A bare session has neither hook, so a well-formed spec is refused.
    const refused = served.app_codes.refused;
    const plug = try wire.call(proto.PartSpec, .plug, .{ .core = .cpu0, .text = "max17048@i2c:riic@0x36" });
    try std.testing.expectEqual(refused, try refusal(plug));
    const fault = try wire.call(proto.PartSpec, .set_fault, .{ .core = .cpu0, .text = "@i2c:riic@0x36=nack:2" });
    try std.testing.expectEqual(refused, try refusal(fault));
    const clear = try wire.call(proto.PartSpec, .clear_fault, .{ .core = .cpu0, .text = "i2c:riic@0x36" });
    try std.testing.expectEqual(refused, try refusal(clear));
}
