//! The Windows arm of the C6 bridge's host sockets (RA8EMU-829): the same
//! nonblocking IPv4 calls as host_sock.zig, through ws2_32. Winsock has no
//! SIGPIPE, so no per-socket opt-out is needed.
const std = @import("std");
const win32 = @import("win32.zig");

const Socket = win32.HANDLE;
const Error = @import("host_sock.zig").Error;
const Address = std.Io.net.Ip4Address;

const af_inet: c_int = 2;
const sock_stream: c_int = 1;
const sock_dgram: c_int = 2;
const sol_socket: c_int = 0xffff;
const so_error: c_int = 0x1007;
const sd_send: c_int = 1;
const fionbio: c_long = @bitCast(@as(u32, 0x8004_667E));
const socket_error: c_int = -1;

const SockaddrIn = extern struct {
    family: u16 = af_inet,
    port: u16,
    addr: u32,
    zero: [8]u8 = @splat(0),
};

extern "ws2_32" fn WSAStartup(version: u16, data: *[512]u8) callconv(.winapi) c_int;
extern "ws2_32" fn socket(family: c_int, kind: c_int, protocol: c_int) callconv(.winapi) Socket;
extern "ws2_32" fn ioctlsocket(s: Socket, command: c_long, arg: *c_ulong) callconv(.winapi) c_int;
extern "ws2_32" fn connect(s: Socket, name: *const SockaddrIn, len: c_int) callconv(.winapi) c_int;
extern "ws2_32" fn getsockopt(s: Socket, level: c_int, name: c_int, value: [*]u8, len: *c_int) callconv(.winapi) c_int;
extern "ws2_32" fn send(s: Socket, bytes: [*]const u8, len: c_int, flags: c_int) callconv(.winapi) c_int;
extern "ws2_32" fn shutdown(s: Socket, how: c_int) callconv(.winapi) c_int;
extern "ws2_32" fn closesocket(s: Socket) callconv(.winapi) c_int;

var started = std.atomic.Value(bool).init(false);

/// Winsock must be started once per process before the first socket.
fn start() Error!void {
    if (started.swap(true, .acq_rel)) return;
    var data: [512]u8 align(8) = undefined;
    if (WSAStartup(0x0202, &data) == 0) return;
    started.store(false, .release);
    return error.SystemResources;
}

pub fn open(stream: bool) Error!Socket {
    try start();
    const s = socket(af_inet, if (stream) sock_stream else sock_dgram, 0);
    if (s == win32.invalid_handle) return lastError();
    errdefer close(s);
    var nonblocking: c_ulong = 1;
    if (ioctlsocket(s, fionbio, &nonblocking) == socket_error) return lastError();
    return s;
}

/// True when the connect finished at once; WouldBlock means it is pending.
pub fn connectTo(s: Socket, address: Address) Error!void {
    const in: SockaddrIn = .{ .port = std.mem.nativeToBig(u16, address.port), .addr = @bitCast(address.bytes) };
    if (connect(s, &in, @sizeOf(SockaddrIn)) == socket_error) return lastError();
}

pub fn finished(s: Socket) Error!void {
    var code: c_int = 0;
    var len: c_int = @sizeOf(c_int);
    if (getsockopt(s, sol_socket, so_error, @ptrCast(&code), &len) == socket_error) return lastError();
    if (code != 0) return mapCode(code);
}

pub fn sendBytes(s: Socket, bytes: []const u8) Error!usize {
    const len: c_int = @intCast(@min(bytes.len, std.math.maxInt(c_int)));
    const got = send(s, bytes.ptr, len, 0);
    if (got == socket_error) return lastError();
    return @intCast(got);
}

/// Winsock has no MSG_TRUNC: a datagram too big for `out` reports MessageTooBig.
pub fn recvBytes(s: Socket, out: []u8) Error!usize {
    const len: c_int = @intCast(@min(out.len, std.math.maxInt(c_int)));
    const got = win32.recv(s, out.ptr, len, 0);
    if (got == socket_error) return lastError();
    return @intCast(got);
}

pub fn shutdownSend(s: Socket) Error!void {
    if (shutdown(s, sd_send) == socket_error) return lastError();
}

pub fn close(s: Socket) void {
    _ = closesocket(s);
}

pub fn readyFor(s: Socket, writable: bool) Error!bool {
    var fds = [_]win32.PollFd{.{ .fd = s, .events = if (writable) win32.poll_out else win32.poll_in, .revents = 0 }};
    const got = win32.WSAPoll(&fds, fds.len, 0);
    if (got == socket_error) return lastError();
    return got != 0;
}

fn lastError() Error {
    return mapCode(win32.WSAGetLastError());
}

/// Winsock error codes onto the bridge's error set.
pub fn mapCode(code: c_int) Error {
    return switch (code) {
        10035, 10036, 10037 => error.WouldBlock,
        10061 => error.ConnectionRefused,
        10053, 10054 => error.ConnectionReset,
        10058 => error.BrokenPipe,
        10050, 10051 => error.NetworkUnreachable,
        10065 => error.HostUnreachable,
        10060 => error.TimedOut,
        10040 => error.MessageTooBig,
        10024, 10055, 10093 => error.SystemResources,
        10013 => error.AccessDenied,
        else => error.Unexpected,
    };
}
