//! `--camera-source webcam[:N]` on Windows (RA8EMU-501): the same consent
//! question and privacy check as Linux, then Media Foundation device N
//! through the source reader into the shared Webcam. Windows has no
//! device paths, so `webcam:PATH` is refused; a bare `webcam` is device 0.
const std = @import("std");
const consent = @import("webcam/consent.zig");
const privacy = @import("webcam/privacy.zig");
const mf_open = @import("mf_open.zig");
const mf_capture = @import("mf_capture.zig");
const source = @import("webcam/input.zig");

pub const request_width: u32 = 640;
pub const request_height: u32 = 480;

/// The device index a webcam ARG names, or null for a path or junk.
pub fn index(arg: []const u8) ?u32 {
    if (arg.len == 0) return 0;
    return std.fmt.parseUnsigned(u8, arg, 10) catch null;
}

/// Asks (unless allowed), checks the privacy setting and opens device N.
pub fn openWith(allocator: std.mem.Allocator, calls: mf_open.Calls, arg: []const u8, grant: consent.Grant, reader: *std.Io.Reader, writer: *std.Io.Writer) !*source.Webcam {
    const n = index(arg) orelse return error.BadDevice;
    var name: [24]u8 = undefined;
    const named = std.fmt.bufPrint(&name, "webcam {d}", .{n}) catch unreachable;
    if (consent.decide(grant, named, reader, writer) == .refused) return error.WebcamRefused;
    try privacy.gate(privacy.host(), writer);
    var opened = try mf_open.open(calls, n, request_width, request_height);
    const cap = mf_capture.MfCapture.create(allocator, opened) catch |err| {
        opened.close();
        return err;
    };
    errdefer cap.capture().closeFn(cap);
    const webcam = try source.Webcam.open(allocator, cap.capture(), cap.agreed(), named);
    cap.setName(named);
    webcam.device_path = cap.named();
    consent.logStart(writer, cap.named()) catch {};
    return webcam;
}
