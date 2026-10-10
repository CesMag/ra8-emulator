//! Covers the host read that never waits (RA8EMU-725).
const std = @import("std");
const ra8 = @import("ra8");
const host_read = ra8.host.host_read;

/// Writes all of `bytes` to a pipe end, as the host side of the test.
fn send(fd: std.posix.fd_t, bytes: []const u8) !void {
    const end: std.Io.File = .{ .handle = fd, .flags = .{ .nonblocking = false } };
    try end.writeStreamingAll(std.testing.io, bytes);
}

test "an idle pipe reads as nothing waiting, not as the end" {
    const ends = try std.Io.Threaded.pipe2(.{});
    defer std.Io.Threaded.closeFd(ends[0]);
    defer std.Io.Threaded.closeFd(ends[1]);
    var bytes: [8]u8 = undefined;
    try std.testing.expectEqual(@as(?usize, null), host_read.read(ends[0], &bytes));
}

test "bytes waiting on a pipe are read, then its closed writer reads as the end" {
    const ends = try std.Io.Threaded.pipe2(.{});
    defer std.Io.Threaded.closeFd(ends[0]);
    try send(ends[1], "ok");
    std.Io.Threaded.closeFd(ends[1]);
    var bytes: [8]u8 = undefined;
    try std.testing.expectEqual(@as(?usize, 2), host_read.read(ends[0], &bytes));
    try std.testing.expectEqualStrings("ok", bytes[0..2]);
    try std.testing.expectEqual(@as(?usize, 0), host_read.read(ends[0], &bytes));
}

test "a file opened by path reads its contents and then the end" {
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();
    try dir.dir.writeFile(std.testing.io, .{ .sub_path = "touch.txt", .data = "1,2\n" });
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = path_buf[0..try dir.dir.realPathFile(std.testing.io, "touch.txt", &path_buf)];
    const handle = try host_read.open(std.testing.io, path);
    defer std.Io.Threaded.closeFd(handle);
    var bytes: [8]u8 = undefined;
    try std.testing.expectEqual(@as(?usize, 4), host_read.read(handle, &bytes));
    try std.testing.expectEqual(@as(?usize, 0), host_read.read(handle, &bytes));
}
