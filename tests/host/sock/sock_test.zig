//! Covers src/host/sock/sock.zig (RA8EMU-850, RA8EMU-1105): bytes sent on
//! one end of a socket arrive on the other, an idle socket reads as
//! WouldBlock, and a send to a closed peer is BrokenPipe, an error the
//! caller handles, not a signal.
const std = @import("std");
const builtin = @import("builtin");
const host_sock = @import("ra8").host.sock;

fn pair() ![2]std.posix.fd_t {
    var fds: [2]std.posix.fd_t = undefined;
    if (std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &fds) != 0) return error.SocketPair;
    return fds;
}

test "sent bytes arrive, and an idle socket would block" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const fds = try pair();
    defer for (fds) |fd| host_sock.close(fd);
    var out: [8]u8 = undefined;
    try std.testing.expect(!try host_sock.readyFor(fds[1], .readable));
    try std.testing.expectError(error.WouldBlock, host_sock.recv(fds[1], &out, std.posix.MSG.DONTWAIT));
    try std.testing.expectEqual(@as(usize, 3), try host_sock.send(fds[0], "abc"));
    try std.testing.expect(try host_sock.readyFor(fds[1], .readable));
    try std.testing.expectEqual(@as(usize, 3), try host_sock.recv(fds[1], &out, 0));
    try std.testing.expectEqualStrings("abc", out[0..3]);
}

test "a send to a closed peer is BrokenPipe" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const fds = try pair();
    defer host_sock.close(fds[0]);
    host_sock.close(fds[1]);
    try std.testing.expectError(error.BrokenPipe, host_sock.send(fds[0], "x"));
}

test "a send after the write side is shut is BrokenPipe, and the peer reads the end" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const fds = try pair();
    defer for (fds) |fd| host_sock.close(fd);
    try host_sock.shutdownSend(fds[0]);
    try std.testing.expectError(error.BrokenPipe, host_sock.send(fds[0], "x"));
    var out: [4]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 0), try host_sock.recv(fds[1], &out, 0));
}
