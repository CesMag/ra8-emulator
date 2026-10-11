//! Opens `--camera-source webcam[:N|PATH]` (RA8EMU-506): the consent gate
//! first, then the V4L2 node, the format negotiation and the webcam input.
//! On Windows the whole open goes to Media Foundation (mf_webcam.zig),
//! on macOS to AVFoundation (av_webcam.zig).
//! The device is asked for 640x480; the converter scales whatever it
//! settles on to the size the firmware programmed. Frames come by read()
//! when the node offers it, otherwise by a memory-mapped stream, which is
//! what most UVC webcams offer.
const std = @import("std");
const builtin = @import("builtin");
const consent = @import("consent.zig");
const privacy = @import("privacy.zig");
const v4l2 = @import("../v4l2_device.zig");
const negotiate = @import("../v4l2_negotiate.zig");
const v4l2_stream = @import("../v4l2_stream.zig");
const source = @import("input.zig");
const mf_open = @import("../mf_open.zig");
const mf_webcam = @import("../mf_webcam.zig");
const av_webcam = @import("../av_webcam.zig");

pub const request_width: u32 = 640;
pub const request_height: u32 = 480;

pub const Error = error{ WebcamRefused, NoCaptureIo };

/// Room for a device name built from `webcam:N`.
const Name = [32]u8;

/// Checks a webcam ARG names a device; does not open it.
pub fn device(arg: []const u8) consent.DeviceError![]const u8 {
    var name: Name = undefined;
    return consent.device(&name, arg);
}

/// The open node behind a Webcam's capture seam; owns its path.
const Node = struct {
    allocator: std.mem.Allocator,
    fd: v4l2.Fd,
    path: []u8,
    /// The memory-mapped stream, when the node has no read() I/O.
    stream: ?v4l2_stream.Stream = null,

    fn capture(self: *Node) source.Capture {
        return .{ .ctx = self, .readFn = read, .closeFn = close };
    }

    fn read(ctx: *anyopaque, out: []u8) bool {
        const self: *Node = @ptrCast(@alignCast(ctx));
        if (self.stream) |*stream| return stream.readFrame(out);
        self.fd.readFrame(out) catch return false;
        return true;
    }

    fn close(ctx: *anyopaque) void {
        const self: *Node = @ptrCast(@alignCast(ctx));
        if (self.stream) |*stream| stream.stop();
        self.fd.close();
        consent.logStopStderr(self.path);
        self.allocator.free(self.path);
        self.allocator.destroy(self);
    }
};

/// Opens the webcam, asking on the terminal unless `allow` is set.
pub fn open(allocator: std.mem.Allocator, io: std.Io, arg: []const u8, allow: bool) !*source.Webcam {
    const grant: consent.Grant = if (allow) .allowed else .ask;
    var answer: [64]u8 = undefined;
    var in = std.Io.File.stdin().readerStreaming(io, &answer);
    var out = std.Io.File.stderr().writerStreaming(io, &.{});
    return openWith(allocator, arg, grant, &in.interface, &out.interface);
}

/// `open` with the consent question's reader and writer passed in.
pub fn openWith(allocator: std.mem.Allocator, arg: []const u8, grant: consent.Grant, reader: *std.Io.Reader, writer: *std.Io.Writer) !*source.Webcam {
    if (builtin.os.tag == .windows) {
        const calls = mf_open.system() orelse return error.NoCaptureIo;
        return mf_webcam.openWith(allocator, calls, arg, grant, reader, writer);
    }
    if (builtin.os.tag == .macos) {
        const n = try av_webcam.preflight(arg, grant, reader, writer);
        const host = av_webcam.system() orelse return error.NoCaptureIo;
        return av_webcam.openPrepared(allocator, host, n, writer);
    }
    return openV4l2(allocator, arg, grant, reader, writer);
}

fn openV4l2(allocator: std.mem.Allocator, arg: []const u8, grant: consent.Grant, reader: *std.Io.Reader, writer: *std.Io.Writer) !*source.Webcam {
    var name: Name = undefined;
    const named = try consent.device(&name, arg);
    if (consent.decide(grant, named, reader, writer) == .refused) return error.WebcamRefused;
    try privacy.gate(privacy.host(), writer);
    const node = try allocator.create(Node);
    errdefer allocator.destroy(node);
    const path = try allocator.dupe(u8, named);
    errdefer allocator.free(path);
    node.* = .{ .allocator = allocator, .fd = try v4l2.Fd.open(path), .path = path };
    errdefer node.fd.close();
    const agreed = try negotiate.negotiate(node.fd.device(), request_width, request_height);
    if (!agreed.read_io) {
        if (!agreed.streaming) return error.NoCaptureIo;
        node.stream = try v4l2_stream.Stream.start(node.fd.device(), node.fd.mapper());
    }
    errdefer if (node.stream) |*stream| stream.stop();
    const webcam = try source.Webcam.open(allocator, node.capture(), agreed, path);
    consent.logStart(writer, path) catch {};
    return webcam;
}
