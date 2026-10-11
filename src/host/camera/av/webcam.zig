//! `--camera-source webcam[:N]` on macOS (RA8EMU-502): the same consent
//! question as Linux and Windows, then the camera permission, then
//! AVFoundation device N at 640x480 2vuy into a Mailbox that the shared
//! Webcam reads as YUYV. macOS has no device paths, so `webcam:PATH`
//! is refused; a bare `webcam` is device 0. A read with no new frame since
//! the last one is a failed read, so the source holds the last picture.
const std = @import("std");
const builtin = @import("builtin");
const consent = @import("../webcam/consent.zig");
const permission = @import("permission.zig");
const objc = @import("objc.zig");
const delegate = @import("delegate.zig");
const frame = @import("frame.zig");
const session = @import("session.zig");
const negotiate = @import("../v4l2/negotiate.zig");
const source = @import("../webcam/input.zig");

/// Everything the open needs from the Mac, gathered up front.
pub const Host = struct {
    rt: objc.Runtime,
    media: delegate.Media,
    syms: session.Symbols,
    permission: permission.Status,
};

/// The device index a webcam ARG names, or null for a path or junk.
pub fn index(arg: []const u8) ?u32 {
    if (arg.len == 0) return 0;
    return std.fmt.parseUnsigned(u8, arg, 10) catch null;
}

/// The layout the Mailbox hands Webcam.
pub fn agreed() negotiate.Agreed {
    const row = session.width * 2;
    return .{ .width = session.width, .height = session.height, .pixelformat = frame.pixelformat(.uyvy), .bytesperline = row, .sizeimage = row * session.height, .streaming = true };
}

const AvCapture = struct {
    allocator: std.mem.Allocator,
    box: frame.Mailbox,
    sink: delegate.Sink = undefined,
    running: session.Session = undefined,
    name: [24]u8 = undefined,
    name_len: usize = 0,

    fn capture(self: *AvCapture) source.Capture {
        return .{ .ctx = self, .readFn = read, .closeFn = close };
    }

    fn read(ctx: *anyopaque, out: []u8) bool {
        const self: *AvCapture = @ptrCast(@alignCast(ctx));
        return self.box.take(out);
    }

    fn close(ctx: *anyopaque) void {
        const self: *AvCapture = @ptrCast(@alignCast(ctx));
        self.running.close();
        self.box.deinit();
        if (self.name_len > 0) consent.logStopStderr(self.name[0..self.name_len]);
        self.allocator.destroy(self);
    }
};

/// Asks (unless allowed), checks the permission and opens device N.
pub fn openWith(allocator: std.mem.Allocator, host: Host, arg: []const u8, grant: consent.Grant, reader: *std.Io.Reader, writer: *std.Io.Writer) !*source.Webcam {
    const n = try preflight(arg, grant, reader, writer);
    return openPrepared(allocator, host, n, writer);
}

/// Validates the device and gets consent before opening host camera libraries.
pub fn preflight(arg: []const u8, grant: consent.Grant, reader: *std.Io.Reader, writer: *std.Io.Writer) !u32 {
    const n = index(arg) orelse return error.BadDevice;
    var name: [24]u8 = undefined;
    const named = std.fmt.bufPrint(&name, "webcam {d}", .{n}) catch unreachable;
    if (consent.decide(grant, named, reader, writer) == .refused) return error.WebcamRefused;
    return n;
}

/// Opens a device after `preflight` has validated its index and consent.
pub fn openPrepared(allocator: std.mem.Allocator, host: Host, n: u32, writer: *std.Io.Writer) !*source.Webcam {
    var name: [24]u8 = undefined;
    const named = std.fmt.bufPrint(&name, "webcam {d}", .{n}) catch unreachable;
    try permission.gate(host.permission, writer);
    const cap = try allocator.create(AvCapture);
    cap.* = .{ .allocator = allocator, .box = frame.Mailbox.init(allocator, .uyvy, session.width, session.height) catch |err| {
        allocator.destroy(cap);
        return err;
    } };
    cap.sink = .{ .media = host.media, .box = &cap.box };
    cap.running = session.open(host.rt, host.syms, n, &cap.sink) catch |err| {
        cap.box.deinit();
        allocator.destroy(cap);
        return err;
    };
    errdefer AvCapture.close(cap);
    const webcam = try source.Webcam.open(allocator, cap.capture(), agreed(), named);
    @memcpy(cap.name[0..named.len], named);
    cap.name_len = named.len;
    webcam.device_path = cap.name[0..cap.name_len];
    consent.logStart(writer, webcam.device_path) catch {};
    return webcam;
}

pub const system_path = "/usr/lib/libSystem.B.dylib";

/// This Mac's runtime, media calls, constants and permission; null off
/// macOS or when anything is missing. The libraries stay loaded.
pub fn system() ?Host {
    if (builtin.os.tag != .macos) return null;
    var av = std.DynLib.open(permission.avfoundation_path) catch return null;
    var keep_libraries = false;
    defer if (!keep_libraries) av.close();
    var cv = std.DynLib.open(delegate.corevideo_path) catch return null;
    defer if (!keep_libraries) cv.close();
    var sys = std.DynLib.open(system_path) catch return null;
    defer if (!keep_libraries) sys.close();
    const video = av.lookup(*const objc.Id, "AVMediaTypeVideo") orelse return null;
    const preset = av.lookup(*const objc.Id, "AVCaptureSessionPreset640x480") orelse return null;
    const key = cv.lookup(*const objc.Id, "kCVPixelBufferPixelFormatTypeKey") orelse return null;
    const host: Host = .{
        .rt = objc.host() orelse return null,
        .media = delegate.host() orelse return null,
        .syms = .{
            .video = video.*,
            .preset = preset.*,
            .format_key = key.*,
            .queue_create = sys.lookup(@FieldType(session.Symbols, "queue_create"), "dispatch_queue_create") orelse return null,
        },
        .permission = permission.host(),
    };
    keep_libraries = true;
    return host;
}
