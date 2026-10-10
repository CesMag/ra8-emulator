//! The RPC byte transport over stdin/stdout (RA8EMU-194). Windows reads and
//! writes the pipes through Win32 (RA8EMU-827); the link is always a pipe pair,
//! so readiness there is PeekNamedPipe's byte count.
const std = @import("std");
const builtin = @import("builtin");
const rpc = @import("ra8_rpc_wire");
const win32 = @import("ra8_host").win32;

const on_windows = builtin.os.tag == .windows;
pub const Handle = std.posix.fd_t;

pub const Stdio = struct {
    input: Handle = if (on_windows) win32.invalid_handle else 0,
    output: Handle = if (on_windows) win32.invalid_handle else 1,

    /// This process's own stdin and stdout.
    pub fn process() Stdio {
        if (!on_windows) return .{};
        return .{ .input = win32.stdHandle(win32.std_input), .output = win32.stdHandle(win32.std_output) };
    }
    pub fn transport(self: *Stdio) rpc.Transport {
        return .{ .ctx = self, .vtable = &vtable };
    }
    const vtable: rpc.Transport.VTable = .{ .send = send, .receive = receive, .poll = poll };
    const arm = if (on_windows) Windows else Posix;
    fn from(ctx: *anyopaque) *Stdio {
        return @ptrCast(@alignCast(ctx));
    }
    fn send(ctx: *anyopaque, bytes: []const u8) rpc.Transport.Error!void {
        const self = from(ctx);
        var at: usize = 0;
        while (at < bytes.len) at += try arm.write(self.output, bytes[at..]);
    }
    fn receive(ctx: *anyopaque, into: []u8) rpc.Transport.Error!usize {
        const self = from(ctx);
        if (!try arm.ready(self.input)) return 0;
        return arm.read(self.input, into);
    }
    fn poll(ctx: *anyopaque) usize {
        const self = from(ctx);
        const ready = arm.ready(self.input) catch true;
        return @intFromBool(ready);
    }
};

const Posix = struct {
    const posix = std.posix;
    fn write(fd: Handle, bytes: []const u8) rpc.Transport.Error!usize {
        const rc = posix.system.write(fd, bytes.ptr, bytes.len);
        return switch (posix.errno(rc)) {
            .SUCCESS => @intCast(rc),
            .INTR, .AGAIN => 0,
            else => error.LinkDown,
        };
    }
    /// True when a read will not block: bytes are waiting or the peer hung up.
    fn ready(fd: Handle) rpc.Transport.Error!bool {
        var fds = [_]posix.pollfd{.{ .fd = fd, .events = posix.POLL.IN, .revents = 0 }};
        _ = posix.poll(&fds, 0) catch return error.LinkDown;
        return fds[0].revents & (posix.POLL.IN | posix.POLL.HUP) != 0;
    }
    fn read(fd: Handle, into: []u8) rpc.Transport.Error!usize {
        const rc = posix.system.read(fd, into.ptr, into.len);
        return switch (posix.errno(rc)) {
            .SUCCESS => @intCast(rc),
            .INTR, .AGAIN => 0,
            else => error.LinkDown,
        };
    }
};

const Windows = struct {
    fn write(pipe: Handle, bytes: []const u8) rpc.Transport.Error!usize {
        const len: win32.DWORD = @intCast(@min(bytes.len, std.math.maxInt(win32.DWORD)));
        var written: win32.DWORD = 0;
        if (!win32.WriteFile(pipe, bytes.ptr, len, &written, null).toBool()) return error.LinkDown;
        return written;
    }
    /// A broken pipe reads as ready so the read reports the hang-up.
    fn ready(pipe: Handle) rpc.Transport.Error!bool {
        const waiting = win32.pipeWaiting(pipe) orelse return true;
        return waiting != 0;
    }
    fn read(pipe: Handle, into: []u8) rpc.Transport.Error!usize {
        const waiting = win32.pipeWaiting(pipe) orelse return error.LinkDown;
        const len: win32.DWORD = @intCast(@min(into.len, waiting));
        var got: win32.DWORD = 0;
        if (!win32.ReadFile(pipe, into.ptr, len, &got, null).toBool()) return error.LinkDown;
        return got;
    }
};
