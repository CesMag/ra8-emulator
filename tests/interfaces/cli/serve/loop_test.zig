//! Covers the hang-up check in src/interfaces/cli/serve/loop.zig
//! (RA8EMU-1163) against real pipes: a pipe is closed once its writer is
//! gone and every byte it sent has been read. Linux polls that as HUP alone;
//! Darwin polls it as readable and HUP, with or without bytes left, which
//! is the case that used to spin `serve --stdio`.
const std = @import("std");
const builtin = @import("builtin");
const loop = @import("cli_app").serve.loop;

/// Writes all of `bytes` to a pipe end, as the client side of the test.
fn send(fd: std.posix.fd_t, bytes: []const u8) !void {
    const end: std.Io.File = .{ .handle = fd, .flags = .{ .nonblocking = false } };
    try end.writeStreamingAll(std.testing.io, bytes);
}

test "a pipe whose writer is still there is not closed" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const ends = try std.Io.Threaded.pipe2(.{});
    defer std.Io.Threaded.closeFd(ends[0]);
    defer std.Io.Threaded.closeFd(ends[1]);
    try std.testing.expect(!try loop.closed(ends[0], .pipe));
    try send(ends[1], "ok");
    try std.testing.expect(!try loop.closed(ends[0], .pipe));
}

test "bytes left behind a hung-up writer keep the pipe open until they are read" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const ends = try std.Io.Threaded.pipe2(.{});
    defer std.Io.Threaded.closeFd(ends[0]);
    try send(ends[1], "ok");
    std.Io.Threaded.closeFd(ends[1]);
    try std.testing.expect(!try loop.closed(ends[0], .pipe));
    var bytes: [8]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 2), try std.posix.read(ends[0], &bytes));
    try std.testing.expect(try loop.closed(ends[0], .pipe));
}

test "a pipe whose writer hung up with nothing sent is closed" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const ends = try std.Io.Threaded.pipe2(.{});
    defer std.Io.Threaded.closeFd(ends[0]);
    std.Io.Threaded.closeFd(ends[1]);
    try std.testing.expect(try loop.closed(ends[0], .pipe));
}
