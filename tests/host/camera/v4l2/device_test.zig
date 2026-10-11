//! Covers src/host/camera/v4l2_device.zig with ordinary device nodes:
//! nothing here needs or opens a camera.
const std = @import("std");
const ra8 = @import("ra8");
const webcam = ra8.host.camera;
const v4l2 = webcam.device;

test "a missing node is refused" {
    if (!v4l2.supported) return error.SkipZigTest;
    try std.testing.expectError(error.OpenFailed, v4l2.Fd.open("/nonexistent/ra8-video9"));
}

test "a node that is not V4L2 fails QUERYCAP, so negotiation refuses it" {
    if (!v4l2.supported) return error.SkipZigTest;
    var fd = try v4l2.Fd.open("/dev/null");
    defer fd.close();
    try std.testing.expectError(error.QueryFailed, webcam.negotiate.negotiate(fd.device(), 320, 240));
}

test "read capture fills a whole frame, and a short read is reported" {
    if (!v4l2.supported) return error.SkipZigTest;
    var zero = try v4l2.Fd.open("/dev/zero");
    defer zero.close();
    var frame = @as([64]u8, @splat(0xAA));
    try zero.readFrame(&frame);
    try std.testing.expectEqualSlices(u8, &(@as([64]u8, @splat(0))), &frame);
    var empty = try v4l2.Fd.open("/dev/null");
    defer empty.close();
    try std.testing.expectError(error.ShortFrame, empty.readFrame(&frame));
}

test "hosts without V4L2 refuse to open anything" {
    if (v4l2.supported) return error.SkipZigTest;
    try std.testing.expectError(error.Unsupported, v4l2.Fd.open("/dev/video0"));
}

test "the mapper maps a page of a real file and unmaps it" {
    if (!v4l2.supported) return error.SkipZigTest;
    var zero = try v4l2.Fd.open("/dev/zero");
    defer zero.close();
    const mapper = zero.mapper();
    const memory = mapper.mapFn(mapper.ctx, 0, 4096) orelse return error.MapFailed;
    try std.testing.expectEqual(@as(usize, 4096), memory.len);
    try std.testing.expectEqual(@as(u8, 0), memory[4095]);
    mapper.unmapFn(mapper.ctx, memory);
    var empty = try v4l2.Fd.open("/dev/null");
    defer empty.close();
    const refused = empty.mapper();
    try std.testing.expect(refused.mapFn(refused.ctx, 0, 4096) == null);
}
