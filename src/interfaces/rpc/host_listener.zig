//! Per-user RPC and GDB discovery for `serve --discover` (RA8EMU-1156).
//! The daemon owns these sockets and pumps them beside its primary transport.
//! Unix hosts bind under $HOME/.config/ra8_emulator; Windows uses loopback TCP.
//! The discovery file lists the RPC address and GDB session ports and is removed
//! with the sockets on clean shutdown.
const std = @import("std");
const builtin = @import("builtin");
const sock_ready = @import("ra8_host").sock.ready;
pub const served = @import("session/server.zig");
const proto = @import("session/rpc.zig");
const ws_transport = @import("ws_transport.zig");
const session_api = @import("ra8_session").api;
const host_gdb = @import("host_gdb.zig");

/// One connected client's receive buffer, as big as the primary transport's.
const rx_size = 2 * proto.Client.Env.max_frame;

/// The listener's address in `serve --listen` textual form.
pub const Address = union(enum) {
    unix: []const u8,
    tcp: std.Io.net.IpAddress,

    /// Write the form ctl's `Spec.parse` reads back.
    pub fn write(self: Address, writer: *std.Io.Writer) !void {
        switch (self) {
            .unix => |path| try writer.print("unix:{s}", .{path}),
            .tcp => |ip| try writer.print("tcp:{f}", .{ip}),
        }
    }
};

/// One entry the discovery file lists.
pub const Listener = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    server: std.Io.net.Server,
    address: Address,
    dir: []const u8,
    socket_path: ?[]const u8,
    discovery_path: []const u8,
    client: ?Client,
    gdb: std.ArrayList(*host_gdb.Session),

    pub const Client = struct {
        conn: ws_transport.Connection,
        host: served.Host,
        rx: []u8,
        /// The client's own context: the served hooks, session and transport
        /// are shared with the daemon; subscriptions belong to this client
        /// alone (RA8EMU-1196) and never clobber the primary connection's feeds.
        context: served.Context,
        /// The context's reply scratch, freed on hangup.
        scratch: []u8,
    };

    /// A fresh per-connection context for one listener client (RA8EMU-1196):
    /// the served hooks, session and transport are shared with the daemon;
    /// subscription state (topics, feeds, pending stop, lcd rate, chunked
    /// load) starts empty, and `scratch` is the client's own reply buffer.
    fn clientContext(base: *served.Context, scratch: []u8) served.Context {
        var context = base.*;
        context.scratch = scratch;
        context.pending = null;
        context.topics = .{ 0, 0 };
        context.uart_feed = null;
        context.lcd_feed = null;
        context.lcd_rate = .{ 0, 0 };
        context.lcd_pending = .{ null, null };
        context.lcd_last_ns = .{ 0, 0 };
        context.lcd_holds = 0;
        context.session_feed = null;
        context.trace_feed = null;
        context.chunks = .{};
        return context;
    }

    /// Bind the per-user address: a Unix socket under $HOME/.config on
    /// Linux and macOS, 127.0.0.1 with an OS-picked port on Windows.
    pub fn bind(gpa: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map) !Listener {
        const home = homeOf(env) orelse return error.NoHome;
        const dir = try std.fs.path.join(gpa, &.{ home, ".config", "ra8_emulator" });
        errdefer gpa.free(dir);
        try std.Io.Dir.cwd().createDirPath(io, dir);
        // Owner-only, so other users cannot reach the listener's sockets or
        // the discovery file through the directory (RA8EMU-1175).
        @import("ra8_session").harness.files.harden(io, std.Io.Dir.cwd(), dir) catch {};

        if (builtin.os.tag == .windows) {
            var address = std.Io.net.IpAddress.parse("127.0.0.1", 0) catch unreachable;
            _ = &address;
            var server = try address.listen(io, .{ .reuse_address = true });
            errdefer server.deinit(io);
            const discovery_path = try std.fs.path.join(gpa, &.{ dir, "discovery" });
            errdefer gpa.free(discovery_path);
            return .{
                .gpa = gpa,
                .io = io,
                .server = server,
                .address = .{ .tcp = server.socket.address },
                .dir = dir,
                .socket_path = null,
                .discovery_path = discovery_path,
                .client = null,
                .gdb = .empty,
            };
        }

        const socket_path = try std.fs.path.join(gpa, &.{ dir, "rpc.sock" });
        errdefer gpa.free(socket_path);
        var server = try (try std.Io.net.UnixAddress.init(socket_path)).listen(io, .{});
        errdefer server.deinit(io);
        const discovery_path = try std.fs.path.join(gpa, &.{ dir, "discovery" });
        errdefer gpa.free(discovery_path);
        return .{
            .gpa = gpa,
            .io = io,
            .server = server,
            .address = .{ .unix = socket_path },
            .dir = dir,
            .socket_path = socket_path,
            .discovery_path = discovery_path,
            .client = null,
            .gdb = .empty,
        };
    }

    /// Write the discovery file listing the RPC address and the sessions,
    /// replacing what was there. The app calls this when sessions change;
    /// deinit removes the file.
    pub fn announce(self: *Listener) !void {
        const file = try std.Io.Dir.cwd().createFile(self.io, self.discovery_path, .{ .truncate = true });
        defer file.close(self.io);
        var staging: [4096]u8 = undefined;
        var writer = file.writer(self.io, &staging);
        const w = &writer.interface;
        try w.print("rpc ", .{});
        try self.address.write(w);
        try w.writeByte('\n');
        for (self.gdb.items) |session| {
            try w.print("session {d} {s}\n", .{ session.port, session.elf });
        }
        try w.flush();
    }

    /// Bind a loopback gdb port for a session and list it in the
    /// discovery file (RA8EMU-1156). `live` is the daemon's served session;
    /// its runs get the gdb budget while a client is attached.
    pub fn addGdb(self: *Listener, elf: []const u8, live: ?*session_api.Session) !u16 {
        var address = std.Io.net.IpAddress.parse("127.0.0.1", 0) catch unreachable;
        _ = &address;
        var listener = try address.listen(self.io, .{ .reuse_address = true });
        errdefer listener.deinit(self.io);
        const owned = try self.gpa.dupe(u8, elf);
        errdefer self.gpa.free(owned);
        const session = try self.gpa.create(host_gdb.Session);
        errdefer self.gpa.destroy(session);
        session.* = .{
            .gpa = self.gpa,
            .io = self.io,
            .elf = owned,
            .port = listener.socket.address.getPort(),
            .listener = listener,
            .live = live,
        };
        try self.gdb.append(self.gpa, session);
        return session.port;
    }

    /// Pump every session's gdb port once, before the RPC client's answer.
    pub fn pumpGdb(self: *Listener) void {
        for (self.gdb.items) |session| session.pump();
    }

    /// Accept a waiting client, then answer what a connected client has
    /// sent, once per turn. `context` is the daemon's Served context;
    /// the client gets its own context over the same
    /// hooks (RA8EMU-1196), `tx` the daemon's reply buffer. A second client
    /// waits until the connected one hangs up.
    pub fn answer(self: *Listener, context: *served.Context, tx: []u8) !void {
        if (self.client == null) try self.acceptClient(context);
        const client = &(self.client orelse return);
        _ = client.host.poll(tx) catch {
            self.dropClient();
            return;
        };
        if (gone(self.io, client.conn.stream.socket.handle)) self.dropClient();
    }

    /// Close everything: the client, the listener, the discovery file and
    /// the socket path.
    pub fn deinit(self: *Listener) void {
        std.Io.Dir.cwd().deleteFile(self.io, self.discovery_path) catch {};
        if (self.socket_path) |path| std.Io.Dir.cwd().deleteFile(self.io, path) catch {};
        self.releaseSession();
        self.gdb.deinit(self.gpa);
        self.server.deinit(self.io);
        self.gpa.free(self.discovery_path);
        if (self.socket_path) |path| self.gpa.free(path);
        self.gpa.free(self.dir);
    }

    /// Drop every borrowed session hook before its owner is replaced.
    fn releaseSession(self: *Listener) void {
        self.dropClient();
        for (self.gdb.items) |session| {
            session.deinit();
            self.gpa.free(session.elf);
            self.gpa.destroy(session);
        }
        self.gdb.clearRetainingCapacity();
    }

    fn acceptClient(self: *Listener, context: *served.Context) !void {
        if (!(try ready(self.io, self.server.socket.handle))) return;
        const stream = try self.server.accept(self.io);
        errdefer stream.close(self.io);
        const rx = try self.gpa.alloc(u8, rx_size);
        errdefer self.gpa.free(rx);
        const scratch = try self.gpa.alloc(u8, proto.max_payload);
        errdefer self.gpa.free(scratch);
        self.client = .{
            .conn = .{ .stream = stream, .io = self.io },
            .host = undefined,
            .rx = rx,
            .context = undefined,
            .scratch = scratch,
        };
        const client = &self.client.?;
        client.context = clientContext(context, scratch);
        client.host = served.Host.init(client.conn.transport(), rx, &client.context);
    }

    fn dropClient(self: *Listener) void {
        const c = &(self.client orelse return);
        // Give up the client's own subscriptions and lcd state; the primary
        // context the hooks share is untouched (RA8EMU-1196).
        served.forget(&c.context);
        c.context.chunks.drop();
        c.conn.close();
        self.gpa.free(c.rx);
        self.gpa.free(c.scratch);
        self.client = null;
    }
};

/// The directory the socket and files live under: $HOME/.config/
/// ra8_emulator (or %USERPROFILE%\.config\ra8_emulator on Windows).
fn homeOf(env: *const std.process.Environ.Map) ?[]const u8 {
    if (env.get("HOME")) |home| return home;
    if (env.get("USERPROFILE")) |home| return home;
    return null;
}

/// True when a client is waiting on the listening socket.
fn ready(io: std.Io, fd: std.posix.fd_t) !bool {
    return (try sock_ready.wait(io, fd, 0)).any();
}

/// True when the peer closed its end (zero bytes behind the peek) or the
/// socket failed in a way that is not "nothing to read yet".
fn gone(io: std.Io, fd: std.posix.fd_t) bool {
    const ready_now = sock_ready.wait(io, fd, 0) catch return true;
    if (!ready_now.any()) return false;
    var byte: [1]u8 = undefined;
    return (sock_ready.takeByte(io, fd, &byte, true) orelse return true) == 0;
}
