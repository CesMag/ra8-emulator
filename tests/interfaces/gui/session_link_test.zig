//! Host tests for the GUI's session link (RA8EMU-751): an in-process served
//! Session on real pipes, a server that speaks another version, and a
//! spawned `serve --stdio` child that exits.
const std = @import("std");
const ra8 = @import("ra8");
const gui_app = @import("gui_app");
const test_paths = @import("test_paths");
const bus = ra8.chip.core.cpu.bus;
const Cpu = ra8.chip.core.cpu.cpu.Cpu;
const api = ra8.session.api;
const Machine = ra8.session.stop_machine.Machine;
const proto = ra8.rpc.session.rpc;
const served = ra8.rpc.session.server;
const rpc = served.rpc_lib;
const Stdio = ra8.rpc.stdio_transport.Stdio;
const session_link = gui_app.session_link;
const Link = session_link.Link;
const State = session_link.State;
const Arrival = session_link.Arrival;

const Env = proto.Client.Env;

/// Writes all of `bytes` to a pipe end, as the host side of the test.
fn send(fd: std.posix.fd_t, bytes: []const u8) !void {
    const end: std.Io.File = .{ .handle = fd, .flags = .{ .nonblocking = false } };
    try end.writeStreamingAll(std.testing.io, bytes);
}

/// Vector table (SP 0x40, reset 0x09) then nops at 0x08.
const Ram = struct {
    bytes: [64]u8 = @splat(0),

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

/// A served Session on the far end of two pipes, and the link's buffers.
const Far = struct {
    gpa: std.mem.Allocator,
    memory: Ram = .{},
    cpu: Cpu = undefined,
    machine: Machine = .{},
    session: api.Session = undefined,
    scratch: [64]u8 = undefined,
    context: served.Context = undefined,
    io: Stdio = .{},
    near: Stdio = .{},
    host: served.Host = undefined,
    buffers: [4][]u8 = undefined,

    fn init(gpa: std.mem.Allocator) !*Far {
        const self = try gpa.create(Far);
        self.* = .{ .gpa = gpa };
        for (&self.buffers, 0..) |*buffer, index| buffer.* = try gpa.alloc(u8, (2 - index % 2) * Env.max_frame);
        @memcpy(self.memory.bytes[0..12], &[_]u8{ 0x40, 0, 0, 0, 0x09, 0, 0, 0, 0x00, 0xBF, 0x00, 0xBF });
        self.cpu = .{ .bus = self.memory.view() };
        try self.cpu.reset(0);
        self.session = .{ .live = .{ .core = .{ .cpu = &self.cpu }, .machine = &self.machine, .budget = 100 } };
        self.context = .{ .session = &self.session, .scratch = &self.scratch };
        const down = try std.Io.Threaded.pipe2(.{});
        const up = try std.Io.Threaded.pipe2(.{});
        self.io = .{ .input = up[0], .output = down[1] };
        self.near = .{ .input = down[0], .output = up[1] };
        self.host = served.Host.init(self.io.transport(), self.buffers[0], &self.context);
        return self;
    }

    fn deinit(self: *Far) void {
        self.hangUp();
        std.Io.Threaded.closeFd(self.near.input);
        std.Io.Threaded.closeFd(self.near.output);
        for (self.buffers) |buffer| self.gpa.free(buffer);
        self.gpa.destroy(self);
    }

    /// The far end goes away, as a session that exits does.
    fn hangUp(self: *Far) void {
        if (self.io.output < 0) return;
        std.Io.Threaded.closeFd(self.io.output);
        std.Io.Threaded.closeFd(self.io.input);
        self.io = .{ .input = -1, .output = -1 };
    }

    fn openLink(self: *Far, link: *Link) void {
        link.open(self.near.transport(), self.buffers[2], self.buffers[3]);
    }

    /// Let both ends take turns until the link pumps something out.
    fn turn(self: *Far, link: *Link) ?Arrival {
        for (0..64) |_| {
            if (self.io.output >= 0) _ = self.host.poll(self.buffers[1]) catch {};
            if (link.pump()) |arrival| return arrival;
            if (link.state == .failed or link.state == .closed) return null;
        }
        return null;
    }
};

test "the link connects to a served session, round-trips a request and closes" {
    const far = try Far.init(std.testing.allocator);
    defer far.deinit();
    var link: Link = undefined;
    far.openLink(&link);
    try std.testing.expectEqual(State.connecting, link.state);
    try std.testing.expectEqual(@as(?Arrival, null), far.turn(&link));
    const want: State = .{ .connected = .{ .version = proto.protocol_version, .caps = proto.capabilities } };
    try std.testing.expectEqual(want, link.state);

    const id = try link.send(proto.ReadRegister, .read_register, .{ .core = .cpu0, .register = .pc });
    const response = far.turn(&link).?.response;
    try std.testing.expectEqual(id, response.id);
    const pc = try proto.decode(proto.U32, response.result.ok);
    try std.testing.expectEqual(@as(u32, 0x08), pc.value);

    link.close();
    try std.testing.expectEqual(State.closed, link.state);
    try std.testing.expectEqual(@as(?Arrival, null), link.pump());
    try std.testing.expectError(error.NotConnected, link.send(proto.Now, .now, .{ .core = .cpu0 }));
}

test "a session that goes away shows as failed: the session exited" {
    const far = try Far.init(std.testing.allocator);
    defer far.deinit();
    var link: Link = undefined;
    far.openLink(&link);
    _ = far.turn(&link);
    try std.testing.expect(link.state == .connected);
    far.hangUp();
    _ = far.turn(&link);
    try std.testing.expectEqual(State{ .failed = .ended }, link.state);
    try std.testing.expectEqualStrings("the session exited", link.state.failed.message());
}

test "a session on another protocol version shows as failed with a version message" {
    const far = try Far.init(std.testing.allocator);
    defer far.deinit();
    var link: Link = undefined;
    far.openLink(&link);
    var frame: [64]u8 = undefined;
    const hello = try rpc.frame.encode(rpc.Hello, rpc.Kind.hello, .{ .caps = 1, .version = rpc.Protocol.version + 1 }, &frame);
    try send(far.io.output, hello);
    try std.testing.expectEqual(@as(?Arrival, null), link.pump());
    try std.testing.expectEqual(State{ .failed = .version_mismatch }, link.state);
    try std.testing.expectEqualStrings("the session speaks another protocol version", link.state.failed.message());
}

/// Pump `link` until it pumps something out or leaves `from`, for ten seconds.
fn pumpWhile(link: *Link, from: std.meta.Tag(State)) !?Arrival {
    const deadline = std.Io.Timestamp.now(std.testing.io, .awake).toMilliseconds() + 10_000;
    while (std.Io.Timestamp.now(std.testing.io, .awake).toMilliseconds() < deadline and link.state == from) {
        if (link.pump()) |arrival| return arrival;
        try std.testing.io.sleep(.fromMilliseconds(1), .awake);
    }
    return null;
}

test "a spawned serve --stdio child connects, answers, and shows as failed once it exits" {
    const gpa = std.testing.allocator;
    var local: session_link.Local = undefined;
    try local.spawn(std.testing.io, test_paths.emulator, "tests/fixtures/fpu/fp_basic.elf");
    errdefer local.child.kill(std.testing.io);
    const rx = try gpa.alloc(u8, 2 * Env.max_frame);
    defer gpa.free(rx);
    const tx = try gpa.alloc(u8, Env.max_frame);
    defer gpa.free(tx);
    var link: Link = undefined;
    link.open(local.transport(), rx, tx);
    _ = try pumpWhile(&link, .connecting);
    try std.testing.expect(link.state == .connected);

    const id = try link.send(proto.ReadRegister, .read_register, .{ .core = .cpu0, .register = .sp });
    const response = (try pumpWhile(&link, .connected)).?.response;
    try std.testing.expectEqual(id, response.id);
    try std.testing.expect((try proto.decode(proto.U32, response.result.ok)).value != 0);

    local.end();
    _ = try pumpWhile(&link, .connected);
    try std.testing.expectEqual(State{ .failed = .ended }, link.state);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, try local.reap());
}
