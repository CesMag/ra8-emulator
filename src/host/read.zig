//! A read of a host handle that never holds up the run (RA8EMU-725).
//!
//! Host stdin under `--console` and the `--touch @PATH` source are polled at
//! board boundaries, so a read with nothing waiting has to come back at once.
//! On POSIX that is poll() with a zero timeout ahead of the read. Windows has
//! no poll() for pipes or files, so there the handle goes through the camera
//! pipe's reader (pipe_windows.zig): PeekNamedPipe for a pipe, and a plain
//! read for a file, which never waits. An interactive Windows console is
//! neither, and goes through console.zig (RA8EMU-723).
const std = @import("std");
const builtin = @import("builtin");
const pipe_windows = @import("camera/pipe_windows.zig");
const host_console = @import("console.zig");

pub const Handle = std.posix.fd_t;
const is_windows = builtin.os.tag == .windows;

/// Standard input's handle, asked for at run time: on Windows it is a
/// HANDLE the process inherits, not descriptor 0.
pub fn stdin() Handle {
    return std.Io.File.stdin().handle;
}

/// Open PATH, a file or a FIFO, for reading. On POSIX the open does not
/// block, so a FIFO with no writer yet does not hold up the run; std.Io
/// has no non-blocking open, so POSIX goes to open(2) directly.
pub fn open(io: std.Io, path: []const u8) !Handle {
    if (is_windows) {
        return (try std.Io.Dir.cwd().openFile(io, path, .{})).handle;
    } else return openNonBlocking(path);
}

fn openNonBlocking(path: []const u8) !Handle {
    const z = try std.posix.toPosixPath(path);
    while (true) {
        const rc = std.posix.system.open(&z, .{ .NONBLOCK = true, .CLOEXEC = true }, @as(c_uint, 0));
        switch (std.posix.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .INTR => continue,
            .NOENT => return error.FileNotFound,
            .ACCES, .PERM => return error.AccessDenied,
            .ISDIR => return error.IsDir,
            else => return error.OpenFailed,
        }
    }
}

/// A handle as the one word a model's byte source carries (ADR 0004): the
/// application pairs it with readWord, so no model holds a host type.
pub fn word(handle: Handle) usize {
    return if (is_windows) @intFromPtr(handle) else @as(u32, @bitCast(handle));
}

/// read() for a handle given as word(): a byte source's read function.
pub fn readWord(context: usize, into: []u8) ?usize {
    const handle: Handle = if (is_windows) @ptrFromInt(context) else @bitCast(@as(u32, @truncate(context)));
    return read(handle, into);
}

/// Close a handle from open() or a pipe. 0.17 has no std.posix.close;
/// libc is always linked, so POSIX calls close(2) directly.
pub fn close(handle: Handle) void {
    if (is_windows) {
        std.os.windows.CloseHandle(handle);
    } else _ = std.c.close(handle);
}

/// Read what is waiting on `handle` into `into`. Null means nothing is
/// waiting (or the read failed) and the caller asks again next boundary;
/// 0 means end of input; anything else is the count read.
pub fn read(handle: Handle, into: []u8) ?usize {
    if (is_windows) {
        if (host_console.isConsole(handle)) return host_console.read(handle, into);
        return pipe_windows.readNow(handle, true, into) catch null;
    } else return readPosix(handle, into);
}

fn readPosix(handle: Handle, into: []u8) ?usize {
    var fds = [_]std.posix.pollfd{
        .{ .fd = handle, .events = std.posix.POLL.IN, .revents = 0 },
    };
    const ready = std.posix.poll(&fds, 0) catch return null;
    // A pipe whose writer has gone reports HUP, not IN; the read then
    // returns 0 so the caller can stop polling.
    const wake = std.posix.POLL.IN | std.posix.POLL.HUP;
    if (ready == 0 or fds[0].revents & wake == 0) return null;
    return std.posix.read(handle, into) catch null;
}
