//! The per-user RPC listener (RA8EMU-1156): while ra8_gui runs, it listens
//! on a per-user address and serves outside clients (ctl, IDEs) on the same
//! Served context the panes draw through. On Linux and macOS that is a Unix
//! socket under $HOME/.config/ra8_emulator; on Windows, 127.0.0.1 with an
//! OS-picked port. The discovery file in the same directory lists the RPC
//! address and one gdb port per session; the app removes the file (and the
//! socket path) on exit. Nothing here spawns the app: a client that finds
//! no listener starts ra8_gui first.
const std = @import("std");
const builtin = @import("builtin");
const sock_ready = @import("ra8_host").sock.ready;
const win32 = @import("ra8_host").win32;
pub const served = @import("session/server.zig");
const proto = @import("session/rpc.zig");
const socket_transport = @import("socket_transport.zig");
const session_api = @import("ra8_session").api;
const host_gdb = @import("host_gdb.zig");

/// One connected client's receive buffer, as big as the shell's own.
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
        conn: socket_transport.Connection,
        host: served.Host,
        rx: []u8,
    };

    /// Bind the per-user address: a Unix socket under $HOME/.config on
    /// Linux and macOS, 127.0.0.1 with an OS-picked port on Windows.
    pub fn bind(gpa: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map) !Listener {
        const home = homeOf(env) orelse return error.NoHome;
        const dir = try std.fs.path.join(gpa, &.{ home, ".config", "ra8_emulator" });
        errdefer gpa.free(dir);
        try std.Io.Dir.cwd().createDirPath(io, dir);

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
    /// discovery file (RA8EMU-1156). `live` is the session the panes draw
    /// through; its runs get the gdb budget while a client is attached.
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

    /// Close one session's gdb port and rewrite the discovery file.
    pub fn removeGdb(self: *Listener, elf: []const u8) void {
        var at: usize = 0;
        while (at < self.gdb.items.len) : (at += 1) {
            const session = self.gdb.items[at];
            if (!std.mem.eql(u8, session.elf, elf)) continue;
            _ = self.gdb.orderedRemove(at);
            session.deinit();
            self.gpa.free(session.elf);
            self.gpa.destroy(session);
            self.announce() catch {};
            return;
        }
    }

    /// Pump every session's gdb port once, before the RPC client's answer.
    pub fn pumpGdb(self: *Listener) void {
        for (self.gdb.items) |session| session.pump();
    }

    /// Accept a waiting client, then answer what a connected client has
    /// sent, once per frame. `context` is the Served context the panes
    /// already draw through, `tx` the shell's reply buffer. A second
    /// client waits until the connected one hangs up.
    pub fn answer(self: *Listener, context: *served.Context, tx: []u8) !void {
        if (self.client == null) try self.acceptClient(context);
        const client = &(self.client orelse return);
        _ = client.host.poll(tx) catch {
            self.dropClient();
            return;
        };
        if (gone(client.conn.stream.socket.handle)) self.dropClient();
    }

    /// Close everything: the client, the listener, the discovery file and
    /// the socket path.
    pub fn deinit(self: *Listener) void {
        std.Io.Dir.cwd().deleteFile(self.io, self.discovery_path) catch {};
        if (self.socket_path) |path| std.Io.Dir.cwd().deleteFile(self.io, path) catch {};
        self.dropClient();
        for (self.gdb.items) |session| {
            session.deinit();
            self.gpa.free(session.elf);
            self.gpa.destroy(session);
        }
        self.gdb.deinit(self.gpa);
        self.server.deinit(self.io);
        self.gpa.free(self.discovery_path);
        if (self.socket_path) |path| self.gpa.free(path);
        self.gpa.free(self.dir);
    }

    fn acceptClient(self: *Listener, context: *served.Context) !void {
        if (!(try ready(self.server.socket.handle))) return;
        const stream = try self.server.accept(self.io);
        errdefer stream.close(self.io);
        const rx = try self.gpa.alloc(u8, rx_size);
        errdefer self.gpa.free(rx);
        self.client = .{
            .conn = .{ .stream = stream, .io = self.io },
            .host = undefined,
            .rx = rx,
        };
        const client = &self.client.?;
        client.host = served.Host.init(client.conn.transport(), rx, context);
    }

    fn dropClient(self: *Listener) void {
        const c = &(self.client orelse return);
        c.conn.close();
        self.gpa.free(c.rx);
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
fn ready(fd: std.posix.fd_t) !bool {
    return (try sock_ready.wait(fd, 0)).any();
}

/// True when the peer closed its end (zero bytes behind the peek) or the
/// socket failed in a way that is not "nothing to read yet".
fn gone(fd: std.posix.fd_t) bool {
    var byte: [1]u8 = undefined;
    if (builtin.os.tag == .windows) {
        const got = win32.recv(fd, &byte, byte.len, win32.msg_peek);
        if (got < 0) return win32.WSAGetLastError() != win32.wsa_would_block;
        return got == 0;
    }
    const flags = std.posix.MSG.PEEK | std.posix.MSG.DONTWAIT;
    const got = std.c.recv(fd, &byte, byte.len, @intCast(flags));
    if (got < 0) return std.c.errno(got) != .AGAIN;
    return got == 0;
}
