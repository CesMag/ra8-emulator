//! Raw frames from a pipe for the camera (RA8EMU-584):
//! `--camera-source pipe:<path|->,<w>x<h>,<rgb24|yuyv|rgb565>`, read here in
//! ra8_host so the camera model never opens a handle (RA8EMU-1011).
//!
//! The pipe is read without blocking. Each capture drains what the writer
//! has sent so far, keeps the newest whole frame and shows it; a frame cut
//! short waits for the rest. Before the first frame arrives the capture is
//! black. A FIFO with no writer yet reads 0 bytes, so a 0-byte read only
//! counts as the writer closing once data has arrived; after that the last
//! frame is held and one line says so. The run never waits on the writer.
//! On Windows the emulator serves `\\.\pipe\NAME` itself (pipe_windows.zig,
//! RA8EMU-585).
const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const decoded = @import("../decoded_image.zig");
const host_read = @import("../../read.zig");
pub const raw = @import("frame.zig");
pub const pipe_windows = @import("windows.zig");
const win = pipe_windows;
const is_windows = builtin.os.tag == .windows;

/// The most whole frames one capture drains, so a writer faster than the
/// run (`cat /dev/zero`) cannot hold a capture forever.
pub const max_frames_per_capture: usize = 64;

pub const Pipe = struct {
    allocator: std.mem.Allocator,
    fd: posix.fd_t,
    owns_fd: bool,
    /// Windows only: `fd` is inherited standard input, peeked before reads.
    stdin: bool = false,
    arg: raw.Arg,
    /// The frame being received, and the newest whole one.
    pending: []u8,
    latest: []u8,
    filled: usize = 0,
    fresh: bool = false,
    seen_data: bool = false,
    closed: bool = false,
    /// Whole frames received over the run.
    frames: u64 = 0,
    image: decoded.Image,

    /// Open the named pipe, or standard input for "-", without blocking.
    pub fn load(allocator: std.mem.Allocator, io: std.Io, text: []const u8) !*Pipe {
        const arg = try raw.parseArg(text);
        const stdin = std.mem.eql(u8, arg.path, "-");
        if (is_windows) {
            const handle = if (stdin) host_read.stdin() else try win.serve(arg.path, arg.frameBytes());
            errdefer if (!stdin) host_read.close(handle);
            const self = try make(allocator, handle, !stdin, arg);
            self.stdin = stdin;
            return self;
        }
        const fd = if (stdin) host_read.stdin() else try host_read.open(io, arg.path);
        errdefer if (!stdin) host_read.close(fd);
        return fromFd(allocator, fd, !stdin, arg);
    }

    /// Read frames from `fd`, which is made non-blocking; closed at the end
    /// only when `owns_fd`.
    pub fn fromFd(allocator: std.mem.Allocator, fd: posix.fd_t, owns_fd: bool, arg: raw.Arg) !*Pipe {
        const flags = std.c.fcntl(fd, std.c.F.GETFL);
        if (flags < 0) return error.FcntlFailed;
        const nonblock: c_int = @bitCast(std.c.O{ .NONBLOCK = true });
        if (std.c.fcntl(fd, std.c.F.SETFL, flags | nonblock) < 0) return error.FcntlFailed;
        return make(allocator, fd, owns_fd, arg);
    }

    fn make(allocator: std.mem.Allocator, fd: posix.fd_t, owns_fd: bool, arg: raw.Arg) !*Pipe {
        const image = try decoded.Image.alloc(allocator, arg.width, arg.height);
        errdefer image.deinit(allocator);
        const pending = try allocator.alloc(u8, arg.frameBytes());
        errdefer allocator.free(pending);
        const latest = try allocator.alloc(u8, arg.frameBytes());
        errdefer allocator.free(latest);
        const self = try allocator.create(Pipe);
        self.* = .{
            .allocator = allocator,
            .fd = fd,
            .owns_fd = owns_fd,
            .arg = arg,
            .pending = pending,
            .latest = latest,
            .image = image,
        };
        @memset(image.pixels, 0);
        return self;
    }

    /// Take whatever the writer has sent, never waiting for more.
    pub fn drain(self: *Pipe) void {
        var whole: usize = 0;
        while (!self.closed and whole < max_frames_per_capture) {
            const got = self.readNow() catch |err| switch (err) {
                error.WouldBlock => return,
                else => return self.hangUp(),
            };
            if (got == 0) return if (self.seen_data) self.hangUp();
            self.seen_data = true;
            self.filled += got;
            if (self.filled < self.pending.len) continue;
            std.mem.swap([]u8, &self.pending, &self.latest);
            self.filled = 0;
            self.fresh = true;
            self.frames += 1;
            whole += 1;
        }
    }

    fn readNow(self: *Pipe) !usize {
        const into = self.pending[self.filled..];
        if (is_windows) return win.readNow(self.fd, self.stdin, into);
        return posix.read(self.fd, into);
    }

    fn hangUp(self: *Pipe) void {
        self.closed = true;
        std.debug.print("--camera-source pipe:{s}: the writer closed after {d} frames; holding the last one\n", .{ self.arg.path, self.frames });
    }

    /// The newest whole frame at a capture: drain what the writer sent and
    /// show it, or keep showing the last one.
    pub fn picture(self: *Pipe, _: u64) decoded.Image {
        self.drain();
        if (self.fresh) raw.toRgb(self.arg.format, self.latest, self.image.pixels);
        self.fresh = false;
        return self.image;
    }

    pub fn close(self: *Pipe) void {
        const allocator = self.allocator;
        if (self.owns_fd) host_read.close(self.fd);
        allocator.free(self.pending);
        allocator.free(self.latest);
        self.image.deinit(allocator);
        allocator.destroy(self);
    }
};
