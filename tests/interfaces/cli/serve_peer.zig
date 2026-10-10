//! A session client on a spawned `ra8_emulator serve` (RA8EMU-737, 736),
//! shared by the stdio and socket tests.
const std = @import("std");
const ra8 = @import("ra8");
const test_paths = @import("test_paths");
const proto = ra8.rpc.session_rpc;
const rpc = ra8.rpc.session_server.rpc_lib;

pub const image_path = "tests/fixtures/fpu/fp_basic.elf";
const Env = proto.Client.Env;
const Incoming = proto.Client.Incoming;

/// A client on `wire` with its buffers off the stack.
pub const Peer = struct {
    gpa: std.mem.Allocator,
    rx: []u8,
    tx: []u8,
    client: proto.Client = undefined,

    pub fn init(gpa: std.mem.Allocator, wire: rpc.Transport) !*Peer {
        const self = try gpa.create(Peer);
        self.* = .{ .gpa = gpa, .rx = try gpa.alloc(u8, 2 * Env.max_frame), .tx = try gpa.alloc(u8, Env.max_frame) };
        self.client = proto.Client.init(wire, self.rx, proto.capabilities);
        return self;
    }

    pub fn deinit(self: *Peer) void {
        self.gpa.free(self.rx);
        self.gpa.free(self.tx);
        self.gpa.destroy(self);
    }

    /// The next frame from the server, or an error after ten seconds.
    fn next(self: *Peer) !Incoming {
        const deadline = std.Io.Timestamp.now(std.testing.io, .awake).toMilliseconds() + 10_000;
        while (std.Io.Timestamp.now(std.testing.io, .awake).toMilliseconds() < deadline) {
            if (try self.client.poll(self.tx)) |incoming| return incoming;
            try std.testing.io.sleep(.fromMilliseconds(1), .awake);
        }
        return error.ServerSilent;
    }

    /// Call `method` and decode its `Reply`, skipping any events on the way.
    fn call(self: *Peer, comptime Reply: type, comptime Args: type, method: proto.Method, args: Args) !Reply {
        _ = try self.client.call(Args, @backingInt(method), args, 0, self.tx);
        while (true) switch (try self.next()) {
            .response => |response| return switch (response.result) {
                .ok => |bytes| try proto.decode(Reply, bytes),
                .err => error.Refused,
            },
            else => {},
        };
    }

    /// Greet, load the fixture over the wire, run, pause and read pc and sp.
    pub fn drive(self: *Peer) !void {
        try self.client.greet(self.tx);
        try std.testing.expectEqual(proto.capabilities, (try self.next()).ready);
        const image = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, image_path, self.gpa, .limited(1 << 20));
        defer self.gpa.free(image);
        _ = try self.call(proto.Ack, proto.Load, .load, .{ .core = .cpu0, .image = image });
        _ = try self.call(proto.Ack, proto.Run, .run, .{ .core = .cpu0, .mode = .cont, .budget = 1000 });
        _ = try self.call(proto.Ack, proto.CoreOnly, .pause, .{ .core = .cpu0 });
        const pc = try self.call(proto.U32, proto.ReadRegister, .read_register, .{ .core = .cpu0, .register = .pc });
        const sp = try self.call(proto.U32, proto.ReadRegister, .read_register, .{ .core = .cpu0, .register = .sp });
        try std.testing.expect(pc.value != 0);
        try std.testing.expect(sp.value != 0);
    }
};

/// A serve started on a listen spec, with the address it said it bound.
pub const Listening = struct { child: std.process.Child, bound: []const u8 };

/// Start `serve --listen spec` on the fixture and read its bound address
/// off stderr into `line`.
pub fn listen(spec: []const u8, line: []u8) !Listening {
    const io = std.testing.io;
    var child = try std.process.spawn(io, .{
        .argv = &.{ test_paths.emulator, "serve", "--listen", spec, image_path },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .pipe,
    });
    errdefer child.kill(io);
    var reader = child.stderr.?.reader(io, line);
    const said = try reader.interface.takeDelimiterExclusive('\n');
    const prefix = "serve: listening on ";
    try std.testing.expect(std.mem.startsWith(u8, said, prefix));
    return .{ .child = child, .bound = said[prefix.len..] };
}
