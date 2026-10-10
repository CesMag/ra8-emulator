//! RPC byte transports over connected TCP and Unix domain sockets (RA8EMU-194).
const std = @import("std");
const rpc = @import("ra8_rpc_wire");
const sock_ready = @import("ra8_host").sock_ready;

pub const Connection = struct {
    stream: std.Io.net.Stream,
    io: std.Io,
    pub fn fromFd(io: std.Io, fd: std.posix.fd_t) Connection {
        return .{ .stream = .{ .socket = .{ .handle = fd, .address = .{ .ip4 = .loopback(0) } } }, .io = io };
    }
    pub fn tcp(io: std.Io, address: std.Io.net.IpAddress) !Connection {
        return .{ .stream = try address.connect(io, .{ .mode = .stream }), .io = io };
    }
    pub fn unix(io: std.Io, path: []const u8) !Connection {
        const address = try std.Io.net.UnixAddress.init(path);
        return .{ .stream = try address.connect(io), .io = io };
    }
    pub fn transport(self: *Connection) rpc.Transport {
        return .{ .ctx = self, .vtable = &vtable };
    }
    pub fn close(self: *Connection) void {
        self.stream.close(self.io);
    }
    const vtable: rpc.Transport.VTable = .{ .send = send, .receive = receive, .poll = poll };
    fn from(ctx: *anyopaque) *Connection {
        return @ptrCast(@alignCast(ctx));
    }
    fn send(ctx: *anyopaque, bytes: []const u8) rpc.Transport.Error!void {
        const self = from(ctx);
        var out = self.stream.writer(self.io, &.{});
        out.interface.writeAll(bytes) catch return error.LinkDown;
    }
    fn receive(ctx: *anyopaque, into: []u8) rpc.Transport.Error!usize {
        const self = from(ctx);
        const ready = sock_ready.wait(self.stream.socket.handle, 0) catch return error.LinkDown;
        if (!ready.any()) return 0;
        var vec = [_][]u8{into};
        const got = self.stream.readWithControl(self.io, &vec, &.{}) catch return error.LinkDown;
        return got.data_len;
    }
    fn poll(ctx: *anyopaque) usize {
        const self = from(ctx);
        const ready = sock_ready.wait(self.stream.socket.handle, 0) catch return 0;
        return @intFromBool(ready.any());
    }
};
