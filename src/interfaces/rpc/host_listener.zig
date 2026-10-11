//! The per-user RPC listener (RA8EMU-1156): while ra8_gui runs, it listens
//! on a per-user address and serves outside clients (ctl, IDEs) on the same
//! Served context the panes draw through. On Linux and macOS that is a Unix
//! socket under $HOME/.config/ra8_emulator; on Windows, 127.0.0.1 with an
//! OS-picked port. The discovery file in the same directory lists the RPC
//! address and one gdb port per session; the app removes the file (and the
//! socket paths) on exit. A second ra8_gui launch connects to the focus
//! address in the same file and exits; the running app raises its window
//! (RA8EMU-1156). Nothing here spawns the app: a client that finds
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
    focus_server: ?std.Io.net.Server,
    focus_address: ?Address,
    focus_path: ?[]const u8,
    focus_requested: bool = false,

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
            var focus_address = std.Io.net.IpAddress.parse("127.0.0.1", 0) catch unreachable;
            _ = &focus_address;
            var focus_server = try focus_address.listen(io, .{ .reuse_address = true });
            errdefer focus_server.deinit(io);
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
                .focus_server = focus_server,
                .focus_address = .{ .tcp = focus_server.socket.address },
                .focus_path = null,
            };
        }

        const socket_path = try std.fs.path.join(gpa, &.{ dir, "rpc.sock" });
        errdefer gpa.free(socket_path);
        var server = try (try std.Io.net.UnixAddress.init(socket_path)).listen(io, .{});
        errdefer server.deinit(io);
        const focus_path = try std.fs.path.join(gpa, &.{ dir, "focus.sock" });
        errdefer gpa.free(focus_path);
        var focus_server = try (try std.Io.net.UnixAddress.init(focus_path)).listen(io, .{});
        errdefer focus_server.deinit(io);
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
            .focus_server = focus_server,
            .focus_address = .{ .unix = focus_path },
            .focus_path = focus_path,
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
        if (self.focus_address) |fa| {
            try w.writeAll("focus ");
            try fa.write(w);
            try w.writeByte('\n');
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

    /// Report a waiting focus request once (RA8EMU-1156): a second launch
    /// connected to the focus address, so the app raises its window.
    pub fn takeFocus(self: *Listener) bool {
        if (self.focus_server) |*server| {
            if (ready(server.socket.handle) catch false) {
                const stream = server.accept(self.io) catch return false;
                stream.close(self.io);
                self.focus_requested = true;
            }
        }
        const asked = self.focus_requested;
        self.focus_requested = false;
        return asked;
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
        if (self.focus_path) |path| std.Io.Dir.cwd().deleteFile(self.io, path) catch {};
        self.dropClient();
        for (self.gdb.items) |session| {
            session.deinit();
            self.gpa.free(session.elf);
            self.gpa.destroy(session);
        }
        self.gdb.deinit(self.gpa);
        if (self.focus_server) |*server| server.deinit(self.io);
        self.server.deinit(self.io);
        self.gpa.free(self.discovery_path);
        if (self.socket_path) |path| self.gpa.free(path);
        if (self.focus_path) |path| self.gpa.free(path);
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

/// The second launch's whole job (RA8EMU-1156): read the discovery file
/// and connect to the running app's focus address; the app raises its
/// window and this launch exits. An error means no running app answered,
/// and the caller runs normally.
pub fn focusRunning(gpa: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map) !void {
    const home = homeOf(env) orelse return error.NoHome;
    const path = try std.fs.path.join(gpa, &.{ home, ".config", "ra8_emulator", "discovery" });
    defer gpa.free(path);
    const text = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(4096)) catch return error.NotRunning;
    defer gpa.free(text);
    const address = try focusAddressOf(text);
    var conn = try connectAddress(io, address);
    conn.close();
}

/// The focus line's address in the discovery file's text.
fn focusAddressOf(text: []const u8) !Address {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const rest = std.mem.trim(u8, line, " \r");
        if (!std.mem.startsWith(u8, rest, "focus ")) continue;
        const spec = std.mem.trim(u8, rest["focus ".len..], " ");
        if (std.mem.startsWith(u8, spec, "unix:")) return .{ .unix = spec["unix:".len..] };
        if (std.mem.startsWith(u8, spec, "tcp:")) {
            const ip = std.Io.net.IpAddress.parse(spec["tcp:".len..], 0) catch return error.BadAddress;
            return .{ .tcp = ip };
        }
        return error.BadAddress;
    }
    return error.NotRunning;
}

fn connectAddress(io: std.Io, address: Address) !socket_transport.Connection {
    return switch (address) {
        .unix => |path| socket_transport.Connection.unix(io, path),
        .tcp => |ip| socket_transport.Connection.tcp(io, ip),
    };
}

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
