const std = @import("std");
const builtin = @import("builtin");
const sock_ready = @import("ra8").interfaces.sock_ready;

fn pair() ![2]std.posix.fd_t {
    var fds: [2]std.posix.fd_t = undefined;
    if (std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &fds) != 0) return error.SocketPair;
    return fds;
}

test "an idle socket is not ready, a written one is readable" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const fds = try pair();
    defer for (fds) |fd| std.Io.Threaded.closeFd(fd);
    try std.testing.expect(!(try sock_ready.wait(fds[0], 0)).any());
    try std.testing.expectEqual(@as(isize, 1), std.c.write(fds[1], "x", 1));
    const ready = try sock_ready.wait(fds[0], 0);
    try std.testing.expect(ready.readable);
}

test "a socket whose peer closed reads as ready" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const fds = try pair();
    defer std.Io.Threaded.closeFd(fds[0]);
    std.Io.Threaded.closeFd(fds[1]);
    try std.testing.expect((try sock_ready.wait(fds[0], 0)).any());
}

test "takeByte peeks without consuming, then takes" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const fds = try pair();
    defer for (fds) |fd| std.Io.Threaded.closeFd(fd);
    var byte: [1]u8 = undefined;
    try std.testing.expectEqual(@as(isize, 2), std.c.write(fds[1], "\x03y", 2));
    try std.testing.expectEqual(@as(?usize, 1), sock_ready.takeByte(fds[0], &byte, true));
    try std.testing.expectEqual(@as(u8, 0x03), byte[0]);
    try std.testing.expectEqual(@as(?usize, 1), sock_ready.takeByte(fds[0], &byte, false));
    try std.testing.expectEqual(@as(u8, 0x03), byte[0]);
    try std.testing.expectEqual(@as(?usize, 1), sock_ready.takeByte(fds[0], &byte, false));
    try std.testing.expectEqual(@as(u8, 'y'), byte[0]);
}

test "takeByte reads 0 once the peer hung up" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const fds = try pair();
    defer std.Io.Threaded.closeFd(fds[0]);
    std.Io.Threaded.closeFd(fds[1]);
    var byte: [1]u8 = undefined;
    try std.testing.expectEqual(@as(?usize, 0), sock_ready.takeByte(fds[0], &byte, true));
}
