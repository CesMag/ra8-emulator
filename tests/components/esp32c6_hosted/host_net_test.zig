//! Covers src/components/esp32c6_hosted/host_net.zig and the socket on it in
//! sock.zig: the C6 reaches the host network only through the Net the
//! application hands over, and with none a live run opens no socket.
const std = @import("std");
const ra8 = @import("ra8");

const esp = ra8.components.esp_hosted;
const Net = esp.host_net.Net;
const Sock = esp.sock.Sock;

/// A host socket layer that records what the C6 asked of it.
const Fake = struct {
    pub const Fd = i32;
    pub const Kind = enum { stream, datagram };
    pub const Connect = enum { done, pending };
    pub const Want = enum { readable, writable };

    pub const whole_datagram: u32 = 0x20;

    var opened: ?Kind = null;
    var closed: ?Fd = null;
    var recv_flags: u32 = 0;

    pub fn open(kind: Kind) !Fd {
        opened = kind;
        return 7;
    }
    pub fn connect(fd: Fd, _: std.Io.net.Ip4Address) !Connect {
        return if (fd == 7) .pending else error.BadSocket;
    }
    pub fn readyFor(fd: Fd, want: Want) !bool {
        return fd == 7 and want == .writable;
    }
    pub fn finished(_: Fd) !void {}
    pub fn send(_: Fd, bytes: []const u8) !usize {
        return bytes.len;
    }
    pub fn recv(_: Fd, out: []u8, flags: u32) !usize {
        recv_flags = flags;
        @memcpy(out[0..2], "hi");
        return 2;
    }
    pub fn shutdownSend(_: Fd) !void {}
    pub fn close(fd: Fd) void {
        closed = fd;
    }
};

const address = std.Io.net.Ip4Address{ .bytes = .{ 127, 0, 0, 1 }, .port = 80 };
const tcp_key = esp.tape.Key{ .proto = .tcp, .ip = .{ 127, 0, 0, 1 }, .port = 80 };

test "a socket goes through the Net the application handed over" {
    Fake.closed = null;
    var run: esp.tape.Tape = .{};
    var sock: Sock = .{};
    try std.testing.expectEqual(esp.sock.Connect.pending, try sock.connect(&run, Net.of(Fake), tcp_key, address));
    try std.testing.expectEqual(Fake.Kind.stream, Fake.opened.?);
    try std.testing.expect(try sock.ready());
    try std.testing.expectEqual(@as(usize, 3), try sock.send("abc"));
    var out: [4]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 2), try sock.recv(&out, .copied));
    try std.testing.expectEqualStrings("hi", out[0..2]);
    try std.testing.expectEqual(@as(u32, 0), Fake.recv_flags);
    _ = try sock.recv(&out, .whole_datagram);
    try std.testing.expectEqual(Fake.whole_datagram, Fake.recv_flags);
    sock.close();
    try std.testing.expectEqual(@as(?Fake.Fd, 7), Fake.closed);
}

test "with no host network a live run opens no socket" {
    var run: esp.tape.Tape = .{};
    var sock: Sock = .{};
    try std.testing.expectError(error.NoHostNetwork, sock.connect(&run, null, tcp_key, address));
    sock.close();
}
