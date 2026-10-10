//! Nonblocking host sockets for the C6 bridge (RA8EMU-850). Zig 0.17's
//! std.Io.net connects and reads blocking, and the bridge is polled on every
//! emulator tick, so these calls go to the OS through std.posix.system.
//! Windows goes through ws2_32 in host_sock_windows.zig (RA8EMU-829).
const std = @import("std");
const builtin = @import("builtin");

const posix = std.posix;
const system = posix.system;
const darwin = builtin.os.tag.isDarwin();
const on_windows = builtin.os.tag == .windows;
const win = @import("host_sock_windows.zig");
const socket_flags = @import("socket_flags.zig");

pub const Fd = posix.socket_t;
pub const invalid: Fd = if (on_windows) @import("win32.zig").invalid_handle else -1;
pub const Address = std.Io.net.Ip4Address;
pub const Kind = enum { stream, datagram };
pub const Connect = enum { done, pending };
pub const Want = enum { readable, writable };
/// The receive flag that reports a datagram's whole size when it did not
/// fit the buffer. Winsock has none: it fails the receive instead.
pub const whole_datagram: u32 = if (on_windows) 0 else posix.MSG.TRUNC;

pub const Error = error{
    WouldBlock,
    ConnectionRefused,
    ConnectionReset,
    BrokenPipe,
    NetworkUnreachable,
    HostUnreachable,
    TimedOut,
    MessageTooBig,
    SystemResources,
    AccessDenied,
    Unexpected,
};

/// An IPv4 socket with no blocking calls and no SIGPIPE.
pub fn open(kind: Kind) Error!Fd {
    if (on_windows) return win.open(kind == .stream);
    const base: u32 = if (kind == .stream) posix.SOCK.STREAM else posix.SOCK.DGRAM;
    const extra: u32 = if (darwin) 0 else posix.SOCK.NONBLOCK | posix.SOCK.CLOEXEC;
    const fd: Fd = @intCast(try check(system.socket(posix.AF.INET, base | extra, 0)));
    errdefer close(fd);
    if (darwin) try darwinFlags(fd);
    if (comptime @hasDecl(posix.SO, "NOSIGPIPE")) {
        const enabled: c_int = 1;
        posix.setsockopt(fd, posix.SOL.SOCKET, posix.SO.NOSIGPIPE, std.mem.asBytes(&enabled)) catch return error.Unexpected;
    }
    return fd;
}

/// Starts a connect; `.pending` means poll for writable, then `finished`.
pub fn connect(fd: Fd, address: Address) Error!Connect {
    if (on_windows) {
        win.connectTo(fd, address) catch |err| switch (err) {
            error.WouldBlock => return .pending,
            else => return err,
        };
        return .done;
    }
    var in: posix.sockaddr.in = .{
        .port = std.mem.nativeToBig(u16, address.port),
        .addr = @bitCast(address.bytes),
    };
    _ = check(system.connect(fd, @ptrCast(&in), @sizeOf(posix.sockaddr.in))) catch |err| switch (err) {
        error.WouldBlock => return .pending,
        else => return err,
    };
    return .done;
}

/// The outcome of a pending connect once the socket polls writable.
pub fn finished(fd: Fd) Error!void {
    if (on_windows) return win.finished(fd);
    var code: c_int = 0;
    var len: posix.socklen_t = @sizeOf(c_int);
    _ = try check(system.getsockopt(fd, posix.SOL.SOCKET, posix.SO.ERROR, @ptrCast(&code), &len));
    if (code != 0) return mapErrno(@fromBackingInt(@intCast(code)));
}

/// Sends without raising SIGPIPE when the peer has closed. The flag covers
/// the hosts with no per-socket opt-out; `open` sets that where there is one.
pub fn send(fd: Fd, bytes: []const u8) Error!usize {
    if (on_windows) return win.sendBytes(fd, bytes);
    return check(system.sendto(fd, @ptrCast(bytes.ptr), bytes.len, socket_flags.nosignal, null, 0));
}

/// Bytes received; with `whole_datagram` on a datagram it is the full size.
pub fn recv(fd: Fd, out: []u8, flags: u32) Error!usize {
    if (on_windows) return win.recvBytes(fd, out);
    return check(system.recvfrom(fd, @ptrCast(out.ptr), out.len, flags, null, null));
}

pub fn shutdownSend(fd: Fd) Error!void {
    if (on_windows) return win.shutdownSend(fd);
    _ = try check(system.shutdown(fd, posix.SHUT.WR));
}

pub fn close(fd: Fd) void {
    if (on_windows) return win.close(fd);
    _ = system.close(fd);
}

/// True when `fd` is ready now for what `want` names.
pub fn readyFor(fd: Fd, want: Want) Error!bool {
    if (on_windows) return win.readyFor(fd, want == .writable);
    const events: i16 = if (want == .writable) posix.POLL.OUT else posix.POLL.IN;
    var descriptors = [_]posix.pollfd{.{ .fd = fd, .events = events, .revents = 0 }};
    return (posix.poll(&descriptors, 0) catch return error.SystemResources) != 0;
}

fn darwinFlags(fd: Fd) Error!void {
    const got = std.c.fcntl(fd, std.c.F.GETFL);
    if (got < 0) return error.Unexpected;
    var flags: std.c.O = @bitCast(@as(u32, @intCast(got)));
    flags.NONBLOCK = true;
    if (std.c.fcntl(fd, std.c.F.SETFL, @as(c_int, @bitCast(flags))) < 0) return error.Unexpected;
    if (std.c.fcntl(fd, std.c.F.SETFD, @as(c_int, std.c.FD_CLOEXEC)) < 0) return error.Unexpected;
}

fn check(rc: anytype) Error!usize {
    const e = posix.errno(rc);
    if (e == .SUCCESS) return @intCast(rc);
    return mapErrno(e);
}

fn mapErrno(e: posix.E) Error {
    return switch (e) {
        .AGAIN, .INPROGRESS => error.WouldBlock,
        .CONNREFUSED => error.ConnectionRefused,
        .CONNRESET => error.ConnectionReset,
        .PIPE => error.BrokenPipe,
        .NETUNREACH => error.NetworkUnreachable,
        .HOSTUNREACH => error.HostUnreachable,
        .TIMEDOUT => error.TimedOut,
        .MSGSIZE => error.MessageTooBig,
        .NOBUFS, .NOMEM, .MFILE, .NFILE => error.SystemResources,
        .ACCES, .PERM => error.AccessDenied,
        else => error.Unexpected,
    };
}
