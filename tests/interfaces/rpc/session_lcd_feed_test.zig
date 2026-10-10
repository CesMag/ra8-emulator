//! Host tests for the LCD dirty-rectangle feed (RA8EMU-789): a client and a
//! served Session with a fake panel, joined over the in-memory loopback.
const std = @import("std");
const ra8 = @import("ra8");
const Bounded = ra8.chip.core.bounded.Bounded;
const rpc = served.rpc_lib;
const bus = ra8.chip.core.cpu.bus;
const Cpu = ra8.chip.core.cpu.cpu.Cpu;
const api = ra8.session.session_api;
const Machine = ra8.session.stop_machine.Machine;
const proto = ra8.rpc.session_rpc;
const served = ra8.rpc.session_server;
const feed = ra8.rpc.session_lcd_feed;

const Env = proto.Client.Env;

/// Vector table (SP 0x40, reset 0x09) then nops, so a step has somewhere to go.
const Ram = struct {
    bytes: [64]u8 = @splat(0),

    fn view(self: *Ram) bus.Bus {
        const code = [_]u8{ 0x40, 0, 0, 0, 0x09, 0, 0, 0, 0x00, 0xBF, 0x00, 0xBF };
        @memcpy(self.bytes[0..code.len], &code);
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

/// A panel whose pixel at (x, y) is the low byte of y * width + x.
const Panel = struct {
    width: u32,
    height: u32,
    captures: usize = 0,
    /// Viewers the served connection has asked the display to watch for.
    watchers: i32 = 0,

    fn shade(self: Panel, x: usize, y: usize) u8 {
        return @truncate(y * self.width + x);
    }

    fn display(self: *Panel) api.Display {
        return .{ .context = self, .waitSettledFn = settled, .frameFn = frame, .watchFn = watch };
    }

    fn watch(context: *anyopaque, on: bool) void {
        const self: *Panel = @ptrCast(@alignCast(context));
        self.watchers += if (on) 1 else -1;
    }

    fn settled(context: *anyopaque, timeout_ns: u64) anyerror!void {
        _ = context;
        _ = timeout_ns;
    }

    fn frame(context: *anyopaque, allocator: std.mem.Allocator) anyerror!api.Frame {
        const self: *Panel = @ptrCast(@alignCast(context));
        self.captures += 1;
        const pixels = try allocator.alloc(u8, self.width * self.height);
        for (0..self.height) |y| for (0..self.width) |x| {
            pixels[y * self.width + x] = self.shade(x, y);
        };
        return .{ .width = self.width, .height = self.height, .pixels = pixels, .virtual_ns = 0 };
    }
};

/// One received lcd_dirty event, its pixels already checked against the panel.
const Got = struct { x: u16, y: u16, width: u16, height: u16, virtual_ns: u64 };

/// Both ends of one served connection, with buffers off the stack.
const Wire = struct {
    gpa: std.mem.Allocator,
    pipes: [2][]u8,
    rx: [2][]u8,
    tx: []u8,
    loop: rpc.Loopback = undefined,
    client: proto.Client = undefined,
    host: served.Host = undefined,
    panel: *const Panel = undefined,
    got: Bounded(Got, 8) = .{},

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

    fn open(self: *Wire, context: *served.Context, panel: *const Panel) !void {
        self.panel = panel;
        self.client = proto.Client.init(self.loop.a(), self.rx[0], proto.capabilities);
        self.host = served.Host.init(self.loop.b(), self.rx[1], context);
        try self.client.greet(self.tx);
        try std.testing.expectEqual(rpc.Step.greeted, try self.host.poll(self.tx));
        _ = (try self.client.poll(self.tx)).?;
    }

    fn call(self: *Wire, comptime Args: type, method: proto.Method, args: Args) !Env.Result {
        _ = try self.client.call(Args, @backingInt(method), args, 0, self.tx);
        try std.testing.expectEqual(rpc.Step.answered, try self.host.poll(self.tx));
        self.got.len = 0;
        var result: ?Env.Result = null;
        while (try self.client.poll(self.tx)) |incoming| switch (incoming) {
            .response => |response| result = response.result,
            .event => |event| try self.record(event.topic, event.payload),
            .ready => return error.Unexpected,
        };
        return result orelse error.NoResponse;
    }

    /// Read the program counter: any answered call pumps the feed.
    fn poke(self: *Wire) !void {
        _ = try self.call(proto.ReadRegister, .read_register, .{ .core = .cpu0, .register = .pc });
    }

    fn record(self: *Wire, topic: u16, payload: []const u8) !void {
        try std.testing.expectEqual(@backingInt(proto.Topic.lcd_dirty), topic);
        const sent = try proto.decode(proto.DirtyRect, payload);
        try std.testing.expectEqual(proto.Core.cpu0, sent.core);
        try std.testing.expectEqual(@as(usize, sent.width) * sent.height, sent.pixels.len);
        try std.testing.expect(sent.pixels.len <= feed.max_pixels);
        for (0..sent.height) |row| for (0..sent.width) |column| {
            const want = self.panel.shade(sent.x + column, sent.y + row);
            try std.testing.expectEqual(want, sent.pixels[row * sent.width + column]);
        };
        try self.got.append(.{ .x = sent.x, .y = sent.y, .width = sent.width, .height = sent.height, .virtual_ns = sent.virtual_ns });
    }
};

/// A session on one bare core with `panel` attached as its display.
const Rig = struct {
    memory: Ram = .{},
    cpu: Cpu = undefined,
    machine: Machine = .{},
    session: api.Session = undefined,
    scratch: [8]u8 = undefined,
    context: served.Context = undefined,

    fn init(self: *Rig, panel: ?*Panel, gpa: ?std.mem.Allocator) !void {
        self.cpu = .{ .bus = self.memory.view() };
        try self.cpu.reset(0);
        self.session = .{ .live = .{ .core = .{ .cpu = &self.cpu }, .machine = &self.machine, .budget = 100 } };
        if (panel) |attached| self.session.attachDisplay(attached.display());
        self.context = .{ .session = &self.session, .scratch = &self.scratch, .gpa = gpa };
    }

    fn refresh(self: *Rig, at_ns: u64, dirty: api.Event.Rect) void {
        self.session.event_stream.publish(.{ .core = .cpu0, .kind = .lcd_frame, .virtual_ns = at_ns, .payload = .{ .frame = .{
            .width = 0,
            .height = 0,
            .generation = at_ns,
            .dirty = dirty,
        } } });
    }
};

fn accepted(result: Env.Result) !void {
    switch (result) {
        .ok => {},
        .err => return error.Refused,
    }
}

const subscribe: proto.Subscription = .{ .core = .cpu0, .topic = .lcd_dirty };

test "a subscribed client gets the dirty rectangle's pixels at the refresh's time, and nothing once it leaves" {
    var panel: Panel = .{ .width = 16, .height = 12 };
    var rig: Rig = .{};
    try rig.init(&panel, std.testing.allocator);
    const wire = try Wire.init(std.testing.allocator);
    defer wire.deinit();
    try wire.open(&rig.context, &panel);

    rig.refresh(5, .{ .x = 0, .y = 0, .width = 16, .height = 12 });
    try wire.poke();
    try std.testing.expectEqual(@as(usize, 0), wire.got.len);

    try accepted(try wire.call(proto.Subscription, .subscribe, subscribe));
    rig.refresh(40, .{ .x = 2, .y = 3, .width = 4, .height = 2 });
    try wire.poke();
    try std.testing.expectEqualSlices(Got, &.{.{ .x = 2, .y = 3, .width = 4, .height = 2, .virtual_ns = 40 }}, wire.got.slice());

    try accepted(try wire.call(proto.Subscription, .unsubscribe, subscribe));
    try std.testing.expect(rig.context.lcd_feed == null);
    rig.refresh(60, .{ .x = 0, .y = 0, .width = 1, .height = 1 });
    try wire.poke();
    try std.testing.expectEqual(@as(usize, 0), wire.got.len);
}

test "refreshes the stream coalesced between polls go out once, as the whole panel, from one capture" {
    var panel: Panel = .{ .width = 16, .height = 12 };
    var rig: Rig = .{};
    try rig.init(&panel, std.testing.allocator);
    const wire = try Wire.init(std.testing.allocator);
    defer wire.deinit();
    try wire.open(&rig.context, &panel);
    try accepted(try wire.call(proto.Subscription, .subscribe, subscribe));

    // The queue keeps only the newest frame per core, so the first rectangle
    // is gone and the feed must send everything.
    rig.refresh(10, .{ .x = 1, .y = 1, .width = 2, .height = 2 });
    rig.refresh(20, .{ .x = 12, .y = 9, .width = 9, .height = 9 });
    const before = panel.captures;
    try wire.poke();
    try std.testing.expectEqual(before + 1, panel.captures);
    try std.testing.expectEqualSlices(Got, &.{.{ .x = 0, .y = 0, .width = 16, .height = 12, .virtual_ns = 20 }}, wire.got.slice());
}

test "a rectangle bigger than one event's cap is split by rows" {
    var panel: Panel = .{ .width = 600, .height = 500 };
    var rig: Rig = .{};
    try rig.init(&panel, std.testing.allocator);
    const wire = try Wire.init(std.testing.allocator);
    defer wire.deinit();
    try wire.open(&rig.context, &panel);
    try accepted(try wire.call(proto.Subscription, .subscribe, subscribe));

    rig.refresh(7, .{ .x = 0, .y = 0, .width = 600, .height = 500 });
    try wire.poke();
    const rows: u16 = @intCast(feed.max_pixels / 600);
    try std.testing.expectEqualSlices(Got, &.{
        .{ .x = 0, .y = 0, .width = 600, .height = rows, .virtual_ns = 7 },
        .{ .x = 0, .y = rows, .width = 600, .height = 500 - rows, .virtual_ns = 7 },
    }, wire.got.slice());
}

test "a subscriber makes the display watch its panel, once, until the last topic or the connection goes" {
    var panel: Panel = .{ .width = 4, .height = 4 };
    var rig: Rig = .{};
    try rig.init(&panel, std.testing.allocator);
    const wire = try Wire.init(std.testing.allocator);
    defer wire.deinit();
    try wire.open(&rig.context, &panel);
    try std.testing.expectEqual(@as(i32, 0), panel.watchers);
    try accepted(try wire.call(proto.Subscription, .subscribe, subscribe));
    try accepted(try wire.call(proto.Subscription, .subscribe, subscribe));
    try std.testing.expectEqual(@as(i32, 1), panel.watchers);
    try accepted(try wire.call(proto.Subscription, .unsubscribe, subscribe));
    try accepted(try wire.call(proto.Subscription, .unsubscribe, subscribe));
    try std.testing.expectEqual(@as(i32, 0), panel.watchers);

    // A connection that goes without unsubscribing is cleaned up by the next.
    try accepted(try wire.call(proto.Subscription, .subscribe, subscribe));
    try std.testing.expectEqual(@as(i32, 1), panel.watchers);
    const again = try Wire.init(std.testing.allocator);
    defer again.deinit();
    try again.open(&rig.context, &panel);
    try std.testing.expectEqual(@as(i32, 0), panel.watchers);
}

test "lcd_dirty is refused without a display or an allocator" {
    var panel: Panel = .{ .width = 4, .height = 4 };
    var bare: Rig = .{};
    try bare.init(null, std.testing.allocator);
    var no_gpa: Rig = .{};
    try no_gpa.init(&panel, null);
    for ([_]*Rig{ &bare, &no_gpa }) |rig| {
        const wire = try Wire.init(std.testing.allocator);
        defer wire.deinit();
        try wire.open(&rig.context, &panel);
        try std.testing.expectError(error.Refused, accepted(try wire.call(proto.Subscription, .subscribe, subscribe)));
        try std.testing.expect(rig.context.lcd_feed == null);
    }
}

test "merge and clip keep rectangles inside the panel" {
    const frame: api.Frame = .{ .width = 10, .height = 8, .pixels = &.{}, .virtual_ns = 0 };
    try std.testing.expectEqual(api.Event.Rect{ .x = 1, .y = 2, .width = 7, .height = 6 }, feed.merge(.{ .x = 1, .y = 2, .width = 2, .height = 2 }, .{ .x = 5, .y = 4, .width = 3, .height = 4 }));
    try std.testing.expectEqual(api.Event.Rect{ .x = 8, .y = 6, .width = 2, .height = 2 }, feed.clip(.{ .x = 8, .y = 6, .width = 9, .height = 9 }, frame));
    try std.testing.expectEqual(api.Event.Rect{ .x = 10, .y = 8, .width = 0, .height = 0 }, feed.clip(.{ .x = 40, .y = 40, .width = 1, .height = 1 }, frame));
}
