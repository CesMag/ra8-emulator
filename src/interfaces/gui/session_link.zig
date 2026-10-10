//! The GUI's connection to a session (RA8EMU-751): a session_rpc client on
//! any byte transport, plus the connection state the shell's status line
//! shows. Nothing blocks; the shell calls `pump` once a frame.
const std = @import("std");
const rpc = @import("ra8_rpc_wire");
const proto = @import("ra8_rpc").session_rpc;
const Stdio = @import("ra8_rpc").stdio_transport.Stdio;

const Env = proto.Client.Env;

/// Why a connection stopped being usable.
pub const Failure = enum {
    /// The session speaks another protocol version.
    version_mismatch,
    /// The session refused the handshake for another reason.
    rejected,
    /// The session went away: the child exited or the socket closed.
    ended,
    /// The session sent something this client cannot read.
    garbled,

    /// The line the status bar shows.
    pub fn message(self: Failure) []const u8 {
        return switch (self) {
            .version_mismatch => "the session speaks another protocol version",
            .rejected => "the session refused the connection",
            .ended => "the session exited",
            .garbled => "the session sent a frame this client cannot read",
        };
    }
};

pub const State = union(enum) {
    connecting,
    connected: struct { version: u16, caps: u32 },
    failed: Failure,
    closed,
};

/// What one pump took off the wire.
pub const Arrival = union(enum) {
    response: struct { id: u32, result: Env.Result },
    event: Env.Event,
};

fn classify(err: proto.Error) Failure {
    return switch (err) {
        error.VersionMismatch => .version_mismatch,
        error.BadMagic, error.Rejected, error.NotReady => .rejected,
        error.LinkDown => .ended,
        else => .garbled,
    };
}

/// A client on one session. It must not move once opened: the client
/// reaches the wire through a pointer to it.
pub const Link = struct {
    inner: rpc.Transport,
    client: proto.Client,
    tx: []u8,
    state: State = .connecting,

    /// Greet the session on `wire`. `rx` (2 * Env.max_frame bytes) and `tx`
    /// (Env.max_frame bytes) must outlive the link.
    pub fn open(self: *Link, wire: rpc.Transport, rx: []u8, tx: []u8) void {
        self.* = .{ .inner = wire, .client = undefined, .tx = tx };
        self.client = proto.Client.init(self.watched(), rx, proto.capabilities);
        self.client.greet(tx) catch |err| self.fail(err);
    }

    /// Take at most one frame off the wire and update the state. Returns
    /// the response or event it carried; a slice in it lives until the
    /// next pump.
    pub fn pump(self: *Link) ?Arrival {
        switch (self.state) {
            .failed, .closed => return null,
            else => {},
        }
        const got = (self.client.poll(self.tx) catch |err| {
            self.fail(err);
            return null;
        }) orelse return null;
        switch (got) {
            .ready => |caps| {
                self.state = .{ .connected = .{ .version = proto.protocol_version, .caps = caps } };
                return null;
            },
            .response => |response| return .{ .response = .{ .id = response.id, .result = response.result } },
            .event => |event| return .{ .event = event },
        }
    }

    /// Send a request and return its id; the response comes back by pump.
    /// A full pending table is back-pressure, not a broken session: the
    /// link stays up, and the caller sends again once answers free slots.
    pub fn send(self: *Link, comptime Args: type, method: proto.Method, args: Args) !u32 {
        if (self.state != .connected) return error.NotConnected;
        return self.client.call(Args, @backingInt(method), args, 0, self.tx) catch |err| {
            if (err != error.TableFull) self.fail(err);
            return err;
        };
    }

    /// Stop using the session. The transport's owner closes it.
    pub fn close(self: *Link) void {
        self.state = .closed;
    }

    fn fail(self: *Link, err: proto.Error) void {
        self.state = .{ .failed = classify(err) };
    }

    /// The wire as the client sees it: a readable end that yields nothing
    /// has hung up, which the library would otherwise wait on forever.
    fn watched(self: *Link) rpc.Transport {
        return .{ .ctx = self, .vtable = &vtable };
    }
    const vtable: rpc.Transport.VTable = .{ .send = relay, .receive = take, .poll = peek };
    fn from(ctx: *anyopaque) *Link {
        return @ptrCast(@alignCast(ctx));
    }
    fn relay(ctx: *anyopaque, bytes: []const u8) rpc.Transport.Error!void {
        return from(ctx).inner.send(bytes);
    }
    fn take(ctx: *anyopaque, into: []u8) rpc.Transport.Error!usize {
        const count = try from(ctx).inner.receive(into);
        return if (count == 0) error.LinkDown else count;
    }
    fn peek(ctx: *anyopaque) usize {
        return from(ctx).inner.poll();
    }
};

/// A `serve --stdio` child of `exe` (ra8_emulator), spoken to over its
/// pipes. The shell itself serves a local image in-process
/// (local_session.zig).
pub const Local = struct {
    child: std.process.Child,
    io: std.Io,
    pipes: Stdio = .{},

    /// Start `exe serve --stdio elf`. Its stderr stays the GUI's.
    pub fn spawn(self: *Local, io: std.Io, exe: []const u8, elf: []const u8) !void {
        const argv: []const []const u8 = &.{ exe, "serve", "--stdio", elf };
        self.* = .{ .io = io, .child = try std.process.spawn(io, .{ .argv = argv, .stdin = .pipe, .stdout = .pipe, .stderr = .inherit }) };
        self.pipes = .{ .input = self.child.stdout.?.handle, .output = self.child.stdin.?.handle };
    }

    pub fn transport(self: *Local) rpc.Transport {
        return self.pipes.transport();
    }

    /// Close the child's stdin, which tells `serve` to exit.
    pub fn end(self: *Local) void {
        if (self.child.stdin) |file| file.close(self.io);
        self.child.stdin = null;
    }

    /// Wait for the child once it has been told to end.
    pub fn reap(self: *Local) !std.process.Child.Term {
        return self.child.wait(self.io);
    }
};
