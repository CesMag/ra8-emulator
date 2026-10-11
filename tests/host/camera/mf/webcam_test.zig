//! Covers src/host/camera/mf_webcam.zig with fake Media Foundation calls:
//! device indexes, the consent question naming "webcam N", a refusal that
//! never starts MF, and a failed start that leaves MF stopped.
const std = @import("std");
const ra8 = @import("ra8");
const webcam = ra8.host.camera.webcam;
const mf = webcam.mf;
const mf_open = webcam.mf_open;
const mf_webcam = webcam.mf_webcam;

const allocator = std.testing.allocator;
var starts: u32 = 0;
var running: i32 = 0;
var start_result: mf.HRESULT = -1;

fn startup() mf.HRESULT {
    starts += 1;
    if (mf.succeeded(start_result)) running += 1;
    return start_result;
}

fn stop() void {
    running -= 1;
}

fn none(_: *?*anyopaque) mf.HRESULT {
    return -1;
}

fn noDevices(_: *anyopaque, _: *?[*]?*anyopaque, _: *u32) mf.HRESULT {
    return -1;
}

fn noReader(_: *anyopaque, _: ?*anyopaque, _: *?*anyopaque) mf.HRESULT {
    return -1;
}

fn free(_: ?*anyopaque) void {}

const calls = mf_open.Calls{ .startup = startup, .shutdown = stop, .create_attributes = none, .create_media_type = none, .enum_devices = noDevices, .create_reader = noReader, .free = free };

fn openAnswering(arg: []const u8, grant: webcam.consent.Grant, answer: []const u8, said: *std.Io.Writer.Allocating) !*webcam.input.Webcam {
    var in = std.Io.Reader.fixed(answer);
    return mf_webcam.openWith(allocator, calls, arg, grant, &in, &said.writer);
}

test "webcam args name a device index; paths are not Windows devices" {
    try std.testing.expectEqual(@as(?u32, 0), mf_webcam.index(""));
    try std.testing.expectEqual(@as(?u32, 3), mf_webcam.index("3"));
    try std.testing.expectEqual(@as(?u32, null), mf_webcam.index("/dev/video0"));
    try std.testing.expectEqual(@as(?u32, null), mf_webcam.index("front"));
}

test "a refusal asks about webcam N and never starts Media Foundation" {
    starts = 0;
    var said = std.Io.Writer.Allocating.init(allocator);
    defer said.deinit();
    try std.testing.expectError(error.WebcamRefused, openAnswering("2", .ask, "n\n", &said));
    try std.testing.expect(std.mem.indexOf(u8, said.written(), "open the host camera webcam 2?") != null);
    try std.testing.expectEqual(@as(u32, 0), starts);
    try std.testing.expectError(error.BadDevice, openAnswering("/dev/video0", .allowed, "", &said));
    try std.testing.expectEqual(@as(u32, 0), starts);
}

test "a failed start or a missing device leaves Media Foundation stopped" {
    var said = std.Io.Writer.Allocating.init(allocator);
    defer said.deinit();
    starts = 0;
    running = 0;
    start_result = -1;
    try std.testing.expectError(error.StartupFailed, openAnswering("", .allowed, "", &said));
    try std.testing.expectEqual(@as(u32, 1), starts);
    start_result = 0;
    try std.testing.expectError(error.NoDevice, openAnswering("0", .ask, "y\n", &said));
    try std.testing.expectEqual(@as(i32, 0), running);
    try std.testing.expect(std.mem.indexOf(u8, said.written(), "capture started") == null);
}
