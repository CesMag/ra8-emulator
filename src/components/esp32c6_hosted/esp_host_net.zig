//! The host network the C6 bridge opens sockets on (RA8EMU-1010). The
//! application fills it from its host socket layer with `Net.of`, so the
//! C6 model never touches a host socket itself. With none, a live or
//! recording run opens no socket and the guest sees the connect fail; a
//! replay needs none.
const std = @import("std");

/// One host socket, opaque to the C6.
pub const Handle = enum(usize) { _ };
pub const Address = std.Io.net.Ip4Address;
pub const Kind = enum { stream, datagram };
pub const Connect = enum { done, pending };

pub const Net = struct {
    open: *const fn (kind: Kind) anyerror!Handle,
    connect: *const fn (socket: Handle, address: Address) anyerror!Connect,
    /// True once the socket can be written, so a pending connect is over.
    writable: *const fn (socket: Handle) anyerror!bool,
    /// The outcome of a connect that was pending; an error means it failed.
    finished: *const fn (socket: Handle) anyerror!void,
    /// Never raises a signal when the peer has closed; the host sees to that.
    send: *const fn (socket: Handle, bytes: []const u8) anyerror!usize,
    recv: *const fn (socket: Handle, out: []u8, flags: u32) anyerror!usize,
    shutdownSend: *const fn (socket: Handle) anyerror!void,
    close: *const fn (socket: Handle) void,

    /// The Net over a host socket namespace: `Fd`, `Kind`, `Connect` and
    /// `Want` types and `open`, `connect`, `readyFor`, `finished`, `send`,
    /// `recv`, `shutdownSend` and `close` functions over an `Fd`.
    pub fn of(comptime Host: type) Net {
        return .{
            .open = Over(Host).open,
            .connect = Over(Host).connect,
            .writable = Over(Host).writable,
            .finished = Over(Host).finished,
            .send = Over(Host).send,
            .recv = Over(Host).recv,
            .shutdownSend = Over(Host).shutdownSend,
            .close = Over(Host).close,
        };
    }
};

fn Over(comptime Host: type) type {
    return struct {
        fn open(kind: Kind) anyerror!Handle {
            return handleOf(try Host.open(switch (kind) {
                inline else => |tag| @field(Host.Kind, @tagName(tag)),
            }));
        }
        fn connect(socket: Handle, address: Address) anyerror!Connect {
            return switch (try Host.connect(fdOf(socket), address)) {
                inline else => |tag| @field(Connect, @tagName(tag)),
            };
        }
        fn writable(socket: Handle) anyerror!bool {
            return Host.readyFor(fdOf(socket), .writable);
        }
        fn finished(socket: Handle) anyerror!void {
            return Host.finished(fdOf(socket));
        }
        fn send(socket: Handle, bytes: []const u8) anyerror!usize {
            return Host.send(fdOf(socket), bytes);
        }
        fn recv(socket: Handle, out: []u8, flags: u32) anyerror!usize {
            return Host.recv(fdOf(socket), out, flags);
        }
        fn shutdownSend(socket: Handle) anyerror!void {
            return Host.shutdownSend(fdOf(socket));
        }
        fn close(socket: Handle) void {
            Host.close(fdOf(socket));
        }

        fn handleOf(fd: Host.Fd) Handle {
            return @fromBackingInt(@intCast(switch (@typeInfo(Host.Fd)) {
                .int => @as(usize, @intCast(fd)),
                .pointer => @intFromPtr(fd),
                else => @compileError("a host socket is an integer or a pointer"),
            }));
        }
        fn fdOf(socket: Handle) Host.Fd {
            return switch (@typeInfo(Host.Fd)) {
                .int => @intCast(@backingInt(socket)),
                .pointer => @ptrFromInt(@backingInt(socket)),
                else => @compileError("a host socket is an integer or a pointer"),
            };
        }
    };
}
