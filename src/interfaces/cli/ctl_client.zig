//! The session client ctl speaks through (RA8EMU-747): one link to a
//! `serve`, one call at a time. The link is a socket to a running `serve`
//! (`--connect`) or the pipes of one ctl starts (`--host`, RA8EMU-196).
const std = @import("std");
const rpc = @import("ra8_rpc_wire");
const proto = @import("ra8_rpc").session_rpc;
const Connection = @import("ra8_rpc").socket_transport.Connection;
const Child = @import("ra8_rpc").child_transport.Child;
const Spec = @import("serve_listen.zig").Spec;

/// Where the server is: a socket spec, or the argv that starts `serve --stdio`.
pub const Target = union(enum) { socket: Spec, spawn: []const []const u8 };

const Link = union(enum) { socket: Connection, child: Child };

const Env = proto.Client.Env;
const Incoming = proto.Client.Incoming;

/// How long ctl waits for any one answer before giving up.
const answer_wait_ms = 30_000;

/// One event frame; the payload lives until the next read.
pub const Event = struct { topic: u16, payload: []const u8 };

pub const Client = struct {
    link: Link,
    rx: []u8,
    tx: []u8,
    client: proto.Client,
    /// The io the client was opened with; its clock paces every wait.
    io: std.Io,
    /// The code of the last refusal, for the error line.
    refused: u16 = 0,

    /// Reach `target` and finish the handshake. Buffers come from
    /// `allocator`, which ctl runs as an arena.
    pub fn open(allocator: std.mem.Allocator, io: std.Io, target: Target) !*Client {
        const self = try allocator.create(Client);
        self.* = .{
            .link = undefined,
            .rx = try allocator.alloc(u8, 2 * Env.max_frame),
            .tx = try allocator.alloc(u8, Env.max_frame),
            .client = undefined,
            .io = io,
        };
        switch (target) {
            .socket => |spec| self.link = .{ .socket = switch (spec) {
                .unix => |path| try Connection.unix(io, path),
                .tcp => |address| try Connection.tcp(io, address),
            } },
            .spawn => |argv| {
                self.link = .{ .child = undefined };
                try self.link.child.spawn(io, argv);
            },
        }
        self.client = proto.Client.init(self.transport(), self.rx, proto.capabilities);
        try self.client.greet(self.tx);
        while (true) switch (try self.next()) {
            .ready => return self,
            else => {},
        };
    }

    pub fn close(self: *Client) void {
        switch (self.link) {
            .socket => |*connection| connection.close(),
            .child => |*child| child.close(),
        }
    }

    fn transport(self: *Client) rpc.Transport {
        return switch (self.link) {
            .socket => |*connection| connection.transport(),
            .child => |*child| child.transport(),
        };
    }

    /// Milliseconds on the monotonic clock, for deadlines.
    pub fn nowMs(self: *const Client) i64 {
        return std.Io.Timestamp.now(self.io, .awake).toMilliseconds();
    }

    /// The next frame from the server, or error.ServerSilent.
    fn next(self: *Client) !Incoming {
        const deadline = self.nowMs() + answer_wait_ms;
        while (self.nowMs() < deadline) {
            if (try self.client.poll(self.tx)) |incoming| return incoming;
            try self.io.sleep(.fromMilliseconds(1), .awake);
        }
        return error.ServerSilent;
    }

    /// Call `method` and decode its `Reply`, skipping events on the way.
    /// A slice in the reply lives until the next call.
    pub fn call(self: *Client, comptime Reply: type, comptime Args: type, method: proto.Method, args: Args) !Reply {
        _ = try self.client.call(Args, @backingInt(method), args, 0, self.tx);
        while (true) switch (try self.next()) {
            .response => |response| switch (response.result) {
                .ok => |bytes| return try proto.decode(Reply, bytes),
                .err => |code| {
                    self.refused = @backingInt(code);
                    return error.Refused;
                },
            },
            else => {},
        };
    }

    /// The next event the server sends, or null once `wait_ms` passes.
    pub fn event(self: *Client, wait_ms: i64) !?Event {
        const deadline = self.nowMs() + wait_ms;
        while (self.nowMs() < deadline) {
            if (try self.client.poll(self.tx)) |incoming| switch (incoming) {
                .event => |sent| return .{ .topic = sent.topic, .payload = sent.payload },
                else => {},
            };
            try self.io.sleep(.fromMilliseconds(1), .awake);
        }
        return null;
    }

    /// The next stop event the server sends.
    pub fn stop(self: *Client) !proto.Stopped {
        while (true) switch (try self.next()) {
            .event => |frame| if (frame.topic == @backingInt(proto.Topic.stop)) {
                return try proto.decode(proto.Stopped, frame.payload);
            },
            else => {},
        };
    }
};
