//! `serve --listen unix:PATH|tcp:[HOST]:PORT` (RA8EMU-736): bind, then
//! serve one client at a time until SIGINT, SIGTERM, SIGHUP or SIGQUIT (a
//! closed terminal or a supervisor stop ends it like the others). An empty host or
//! `localhost` binds 127.0.0.1; any other host must be an IP literal. The
//! bound address goes to stderr, and a Unix socket path is removed on exit.
const std = @import("std");
const builtin = @import("builtin");
const sock_ready = @import("ra8_host").sock.ready;
const win32 = @import("ra8_host").win32;
const served = @import("ra8_rpc").session.server;
const Connection = @import("ra8_rpc").socket_transport.Connection;
const loop = @import("loop.zig");

/// How long the accept loop waits for a client before checking for a stop.
const accept_wait_ms = 20;

pub const Spec = union(enum) {
    unix: []const u8,
    tcp: std.Io.net.IpAddress,

    pub fn parse(text: []const u8) !Spec {
        if (std.mem.startsWith(u8, text, "unix:")) {
            const path = text["unix:".len..];
            if (path.len == 0) return error.BadListen;
            return .{ .unix = path };
        }
        if (!std.mem.startsWith(u8, text, "tcp:")) return error.BadListen;
        const rest = text["tcp:".len..];
        const colon = std.mem.lastIndexOfScalar(u8, rest, ':') orelse return error.BadListen;
        const port = std.fmt.parseInt(u16, rest[colon + 1 ..], 10) catch return error.BadListen;
        const host = std.mem.trim(u8, rest[0..colon], "[]");
        const named = if (host.len == 0 or std.mem.eql(u8, host, "localhost")) "127.0.0.1" else host;
        return .{ .tcp = std.Io.net.IpAddress.parse(named, port) catch return error.BadListen };
    }
};

/// Bind `spec` and answer clients one after another until a stop signal.
pub fn serve(io: std.Io, spec: Spec, context: *served.Context, buffers: loop.Buffers) !void {
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    var server = switch (spec) {
        .unix => |path| try (try std.Io.net.UnixAddress.init(try @import("ra8_host").sock.path.unix(io, path, &path_buffer))).listen(io, .{}),
        .tcp => |*tcp| try tcp.listen(io, .{ .reuse_address = true }),
    };
    defer server.deinit(io);
    defer switch (spec) {
        .unix => |path| std.Io.Dir.cwd().deleteFile(io, path) catch {},
        .tcp => {},
    };
    catchStops();
    switch (spec) {
        .unix => |path| std.debug.print("serve: listening on unix:{s}\n", .{path}),
        .tcp => std.debug.print("serve: listening on tcp:{f}\n", .{server.socket.address}),
    }
    while (!loop.stopping.load(.acquire)) {
        if (context.session.persistent_recorder) |rec| try rec.maybeCommit(rec.now());
        if (!try ready(io, server.socket.handle)) continue;
        const client = try server.accept(io);
        var connection: Connection = .{ .stream = client, .io = io };
        defer connection.close();
        loop.answer(io, context, connection.transport(), client.socket.handle, .socket, buffers) catch |err| {
            std.debug.print("serve: client dropped: {s}\n", .{@errorName(err)});
        };
    }
}

/// True when a client is waiting on the listening socket.
fn ready(io: std.Io, fd: std.posix.fd_t) !bool {
    return (try sock_ready.wait(io, fd, accept_wait_ms)).any();
}

/// SIGINT, SIGTERM, SIGHUP and SIGQUIT end the serve cleanly at the next idle
/// check, so the exit is 0 and a Unix socket path is removed. Windows
/// has no POSIX signals, so Ctrl+C, Ctrl+Break and console close do it there.
fn catchStops() void {
    if (builtin.os.tag == .windows) {
        _ = win32.SetConsoleCtrlHandler(onConsoleStop, .TRUE);
        return;
    }
    const action: std.posix.Sigaction = .{
        .handler = .{ .handler = onStop },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.TERM, &action, null);
    std.posix.sigaction(std.posix.SIG.INT, &action, null);
    std.posix.sigaction(std.posix.SIG.HUP, &action, null);
    std.posix.sigaction(std.posix.SIG.QUIT, &action, null);
}

fn onStop(_: std.posix.SIG) callconv(.c) void {
    loop.stopping.store(true, .release);
}

fn onConsoleStop(_: win32.DWORD) callconv(.winapi) win32.BOOL {
    loop.stopping.store(true, .release);
    return .TRUE;
}

/// True when `address` is loopback, the only TCP listener that may serve
/// state files without --allow-state-files (RA8EMU-1175).
pub fn isLoopback(address: std.Io.net.IpAddress) bool {
    return switch (address) {
        .ip4 => |v| v.bytes[0] == 127,
        .ip6 => |v| std.mem.allEqual(u8, v.bytes[0..15], 0) and v.bytes[15] == 1,
    };
}

/// True when snapshot and restore may be served on `spec`: any Unix socket,
/// a loopback TCP listener, or a TCP listener the operator opened to state
/// files with --allow-state-files (RA8EMU-1175).
pub fn allowsState(spec: Spec, allow_state_files: bool) bool {
    return switch (spec) {
        .unix => true,
        .tcp => |address| allow_state_files or isLoopback(address),
    };
}
