//! Covers src/host/camera/webcam/open.zig without a camera: the gate,
//! the device name and the refusals from ordinary device nodes.
const std = @import("std");
const builtin = @import("builtin");
const ra8 = @import("ra8");
const webcam = ra8.host.camera.webcam;
const opener = webcam.open;

const allocator = std.testing.allocator;

fn openAnswering(arg: []const u8, grant: webcam.consent.Grant, answer: []const u8, said: *std.Io.Writer.Allocating) !*webcam.input.Webcam {
    var in = std.Io.Reader.fixed(answer);
    return opener.openWith(allocator, arg, grant, &in, &said.writer);
}

test "a refused question opens nothing" {
    var said = std.Io.Writer.Allocating.init(allocator);
    defer said.deinit();
    const arg = if (builtin.os.tag == .macos) "0" else "/nonexistent/video9";
    try std.testing.expectError(error.WebcamRefused, openAnswering(arg, .ask, "n\n", &said));
    const question = if (builtin.os.tag == .macos) "webcam 0" else "open the host camera /nonexistent/video9?";
    try std.testing.expect(std.mem.indexOf(u8, said.written(), question) != null);
}

test "a yes reaches the device, and a node that is not V4L2 is refused" {
    if (!webcam.device.supported) return error.SkipZigTest;
    var said = std.Io.Writer.Allocating.init(allocator);
    defer said.deinit();
    try std.testing.expectError(error.QueryFailed, openAnswering("/dev/null", .ask, "y\n", &said));
    try std.testing.expectError(error.OpenFailed, openAnswering("/nonexistent/video9", .allowed, "", &said));
    try std.testing.expect(std.mem.indexOf(u8, said.written(), "capture started") == null);
}

test "device names follow the consent gate's rules" {
    try std.testing.expectEqualStrings("/dev/video0", try opener.device(""));
    try std.testing.expectEqualStrings("/dev/x", try opener.device("/dev/x"));
    try std.testing.expectError(error.BadDevice, opener.device("front"));
}
