//! Whether a socket has bytes waiting or its peer hung up (RA8EMU-828).
//! Posix asks poll; Windows asks WSAPoll, which takes the same shape.
const std = @import("std");
const builtin = @import("builtin");
const win32 = @import("win32.zig");

pub const Handle = std.posix.fd_t;

pub const Ready = struct {
    readable: bool = false,
    hung_up: bool = false,

    /// True when a read will not block.
    pub fn any(self: Ready) bool {
        return self.readable or self.hung_up;
    }
};

/// Wait up to `ms` (0 checks without waiting) for `handle` to turn ready.
pub fn wait(handle: Handle, ms: i32) error{SystemResources}!Ready {
    if (builtin.os.tag == .windows) return waitWindows(handle, ms);
    const posix = std.posix;
    var fds = [_]posix.pollfd{.{ .fd = handle, .events = posix.POLL.IN, .revents = 0 }};
    _ = posix.poll(&fds, ms) catch return error.SystemResources;
    const got = fds[0].revents;
    return .{ .readable = got & posix.POLL.IN != 0, .hung_up = got & posix.POLL.HUP != 0 };
}

fn waitWindows(handle: Handle, ms: i32) error{SystemResources}!Ready {
    var fds = [_]win32.PollFd{.{ .fd = handle, .events = win32.poll_in, .revents = 0 }};
    if (win32.WSAPoll(&fds, fds.len, ms) < 0) return error.SystemResources;
    const got = fds[0].revents;
    return .{ .readable = got & win32.poll_in != 0, .hung_up = got & (win32.poll_hup | win32.poll_err) != 0 };
}

/// Reads (or with `peek`, looks at) one byte without consuming more; null
/// when the receive fails, 0 when the peer hung up (RA8EMU-943).
pub fn takeByte(handle: Handle, byte: *[1]u8, peek: bool) ?usize {
    if (builtin.os.tag == .windows) {
        const got = win32.recv(handle, byte, byte.len, if (peek) win32.msg_peek else 0);
        if (got < 0) return null;
        return @intCast(got);
    }
    const got = std.c.recv(handle, byte, byte.len, if (peek) @intCast(std.posix.MSG.PEEK) else 0);
    if (got < 0) return null;
    return @intCast(got);
}
