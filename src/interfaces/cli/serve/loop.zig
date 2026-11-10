//! The answer loop the serve front runs on one connected peer (RA8EMU-736).
const std = @import("std");
const builtin = @import("builtin");
const served = @import("ra8_rpc").session.server;
const Stdio = @import("ra8_rpc").stdio_transport.Stdio;
const sock_ready = @import("ra8_host").sock.ready;
const win32 = @import("ra8_host").win32;

/// How long an idle server waits on its peer before checking again.
const idle_wait_ms = 20;

pub const Buffers = struct {
    rx: []u8,
    tx: []u8,
    listener: ?*@import("ra8_rpc").host_listener.Listener = null,

    pub fn pump(self: Buffers, context: *served.Context) !void {
        if (self.listener) |listener| {
            listener.pumpGdb();
            try listener.answer(context, self.tx);
        }
    }
};

/// What the peer's descriptor is, which decides how a hang-up shows.
pub const Link = enum { pipe, socket };

/// Set from a signal handler; the loops end at their next idle check.
pub var stopping = std.atomic.Value(bool).init(false);

/// Answer the client on stdin and stdout until stdin closes.
pub fn answerStdio(io: std.Io, context: *served.Context, buffers: Buffers) !void {
    var stdio = Stdio.process();
    try answer(io, context, stdio.transport(), stdio.input, .pipe, buffers);
}

/// Answer frames on `wire` until the peer behind `fd` closes or a stop is asked.
pub fn answer(io: std.Io, context: *served.Context, wire: served.rpc_lib.Transport, fd: std.posix.fd_t, link: Link, buffers: Buffers) !void {
    var host = served.Host.init(wire, buffers.rx, context);
    while (true) {
        try buffers.pump(context);
        const polled = host.poll(buffers.tx) catch |err| {
            if (err == error.LinkDown and try closed(io, fd, link)) return;
            return err;
        };
        if (polled != .idle) continue;
        if (stopping.load(.acquire) or try closed(io, fd, link)) return;
    }
}

/// Wait briefly on `fd`; true once the peer hung up with nothing left to read.
/// A socket reports that as readable with zero bytes behind it, so the socket
/// is peeked. A pipe reports HUP: alone on Linux once it is drained, but with
/// readable beside it on Darwin whether or not bytes are left, so a pipe that
/// reads as both is asked what it still holds.
pub fn closed(io: std.Io, fd: std.posix.fd_t, link: Link) !bool {
    if (on_windows and link == .pipe) return pipeClosed(fd);
    const ready = try sock_ready.wait(io, fd, idle_wait_ms);
    if (!ready.readable) return ready.hung_up;
    if (link == .pipe) return ready.hung_up and pipeDrained(fd);
    return peerGone(io, fd);
}

const on_windows = builtin.os.tag == .windows;

/// FIONREAD, the bytes a read would take now. Zig 0.17's std names the
/// request for Linux; Darwin's <sys/filio.h> gives _IOR('f', 127, int).
fn pipeDrained(pipe: std.posix.fd_t) bool {
    if (on_windows) return false;
    const request: c_int = if (builtin.os.tag.isDarwin()) 0x4004667f else std.posix.T.FIONREAD;
    var waiting: c_int = 0;
    if (std.c.ioctl(pipe, request, &waiting) != 0) return false;
    return waiting == 0;
}

/// Windows pipes have no wait; an empty pipe sleeps the idle wait instead.
fn pipeClosed(pipe: std.posix.fd_t) bool {
    const waiting = win32.pipeWaiting(pipe) orelse return true;
    if (waiting == 0) win32.Sleep(idle_wait_ms);
    return false;
}

/// Peek one byte: zero bytes means the peer closed its end.
fn peerGone(io: std.Io, fd: std.posix.fd_t) bool {
    var byte: [1]u8 = undefined;
    return (sock_ready.takeByte(io, fd, &byte, true) orelse return true) == 0;
}
