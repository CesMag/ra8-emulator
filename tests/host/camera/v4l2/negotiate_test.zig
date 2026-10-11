//! Covers src/host/camera/v4l2_abi.zig and v4l2_negotiate.zig against a
//! mock V4L2 device.
const std = @import("std");
const builtin = @import("builtin");
const ra8 = @import("ra8");
const webcam = ra8.host.camera;
const abi = webcam.v4l2;
const negotiate = webcam.negotiate;

/// A webcam that offers `formats` at one fixed size, like a UVC camera
/// that rounds every request to its nearest mode.
const Mock = struct {
    caps: u32 = abi.cap_video_capture | abi.cap_streaming,
    formats: []const u32 = &.{abi.pix_yuyv},
    width: u32 = 640,
    height: u32 = 480,
    querycap_errno: u16 = 0,
    calls: u32 = 0,

    fn ioctl(ctx: *anyopaque, request: u32, arg: *anyopaque) u16 {
        const self: *Mock = @ptrCast(@alignCast(ctx));
        self.calls += 1;
        if (request == abi.vidioc_querycap) {
            const cap: *abi.Capability = @ptrCast(@alignCast(arg));
            cap.capabilities = self.caps;
            return self.querycap_errno;
        }
        if (request != abi.vidioc_s_fmt) return 25;
        const fmt: *abi.Format = @ptrCast(@alignCast(arg));
        const pix = &fmt.fmt.pix;
        if (std.mem.indexOfScalar(u32, self.formats, pix.pixelformat) == null) pix.pixelformat = self.formats[0];
        pix.width = self.width;
        pix.height = self.height;
        pix.bytesperline = self.width * 2;
        pix.sizeimage = self.width * self.height * 2;
        return 0;
    }

    fn device(self: *Mock) negotiate.Device {
        return .{ .ctx = self, .ioctlFn = ioctl };
    }
};

test "the ABI matches videodev2.h on a 64-bit host" {
    try std.testing.expectEqual(@as(usize, 104), @sizeOf(abi.Capability));
    try std.testing.expectEqual(@as(usize, 48), @sizeOf(abi.PixFormat));
    try std.testing.expectEqual(@as(u32, 0x80685600), abi.vidioc_querycap);
    if (@sizeOf(usize) == 8) {
        try std.testing.expectEqual(@as(usize, 208), @sizeOf(abi.Format));
        try std.testing.expectEqual(@as(u32, 0xC0D05605), abi.vidioc_s_fmt);
        try std.testing.expectEqual(@as(u32, 0xC0D05604), abi.vidioc_g_fmt);
    }
    try std.testing.expectEqual(@as(u32, 0x56595559), abi.pix_yuyv);
}

test "a YUYV webcam agrees YUYV at the size it rounds to" {
    var mock: Mock = .{};
    const got = try negotiate.negotiate(mock.device(), 320, 240);
    try std.testing.expectEqual(abi.pix_yuyv, got.pixelformat);
    try std.testing.expectEqual(@as(u32, 640), got.width);
    try std.testing.expectEqual(@as(u32, 480), got.height);
    try std.testing.expectEqual(@as(u32, 1280), got.bytesperline);
    try std.testing.expect(got.streaming);
}

test "a webcam without YUYV falls back to RGB565" {
    var mock: Mock = .{ .formats = &.{abi.pix_rgb565} };
    const got = try negotiate.negotiate(mock.device(), 320, 240);
    try std.testing.expectEqual(abi.pix_rgb565, got.pixelformat);
}

test "a webcam with neither format is refused" {
    var mock: Mock = .{ .formats = &.{abi.fourcc("MJPG")} };
    try std.testing.expectError(error.NoUsableFormat, negotiate.negotiate(mock.device(), 320, 240));
}

test "a node that cannot capture, or has no I/O, is refused before any format" {
    var output: Mock = .{ .caps = 0x2 | abi.cap_streaming };
    try std.testing.expectError(error.NotCapture, negotiate.negotiate(output.device(), 320, 240));
    try std.testing.expectEqual(@as(u32, 1), output.calls);
    var no_io: Mock = .{ .caps = abi.cap_video_capture };
    try std.testing.expectError(error.NoIo, negotiate.negotiate(no_io.device(), 320, 240));
}

test "device_caps wins when the driver reports it" {
    var mock: Mock = .{ .caps = abi.cap_device_caps | abi.cap_video_capture | abi.cap_readwrite };
    var cap: abi.Capability = .{ .capabilities = mock.caps, .device_caps = abi.cap_readwrite };
    try std.testing.expectEqual(abi.cap_readwrite, cap.node());
    try std.testing.expectError(error.NotCapture, negotiate.negotiate(mock.device(), 320, 240));
}

test "a failed QUERYCAP refuses" {
    var mock: Mock = .{ .querycap_errno = 13 };
    try std.testing.expectError(error.QueryFailed, negotiate.negotiate(mock.device(), 320, 240));
    _ = builtin;
}
