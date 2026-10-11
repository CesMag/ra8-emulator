//! Covers src/host/camera/webcam/input.zig with a fake capture, and the
//! label and detail the camera's hosted source gives it.
const std = @import("std");
const ra8 = @import("ra8");
const webcam = ra8.host.camera.webcam;
const abi = webcam.v4l2;
const ws = webcam.input;

/// Hands out `frame` on every read until `fail` is set.
const Fake = struct {
    frame: []const u8,
    fail: bool = false,
    reads: u32 = 0,
    closed: bool = false,

    fn read(ctx: *anyopaque, out: []u8) bool {
        const self: *Fake = @ptrCast(@alignCast(ctx));
        self.reads += 1;
        if (self.fail) return false;
        @memcpy(out, self.frame);
        return true;
    }

    fn close(ctx: *anyopaque) void {
        const self: *Fake = @ptrCast(@alignCast(ctx));
        self.closed = true;
    }

    fn capture(self: *Fake) ws.Capture {
        return .{ .ctx = self, .readFn = read, .closeFn = close };
    }
};

fn agreed(pixelformat: u32, bytesperline: u32) webcam.negotiate.Agreed {
    return .{ .width = 2, .height = 2, .pixelformat = pixelformat, .bytesperline = bytesperline, .sizeimage = bytesperline * 2, .streaming = false, .read_io = true };
}

test "a padded RGB565 frame decodes row by row and reaches the firmware as RGB565" {
    // Two rows of two pixels, 6 bytes a row: 4 of pixels, 2 of padding.
    const bytes = [_]u8{ 0x00, 0xF8, 0xE0, 0x07, 0xEE, 0xEE, 0x1F, 0x00, 0xFF, 0xFF, 0xEE, 0xEE };
    var fake: Fake = .{ .frame = &bytes };
    const control: u8 = 0; // whatever hosted.formatFor maps 0 to
    const self = try ws.Webcam.open(std.testing.allocator, fake.capture(), agreed(abi.pix_rgb565, 6), "/dev/video0");
    const source = try ra8.components.camera.hosted.Hosted(ws.Webcam).open(std.testing.allocator, self, &control, "webcam", self.device_path);
    try std.testing.expectEqualStrings("webcam", source.label);
    try std.testing.expectEqualStrings("/dev/video0", source.detail);
    source.frame(0, .{ .width = 4, .lines = 2 });
    try std.testing.expectEqual(@as(u64, 1), self.frames);
    try std.testing.expectEqual(@as(u8, 255), self.image.get(0)[0]);
    try std.testing.expectEqual(@as(u8, 255), self.image.get(1)[1]);
    try std.testing.expectEqual(@as(u8, 255), self.image.get(2)[2]);
    try std.testing.expectEqual(@as(u8, 255), self.image.get(3)[0]);
    source.close();
    try std.testing.expect(fake.closed);
}

test "a YUYV frame decodes through the shared chroma pair" {
    // Mid-grey: Y 126, U and V neutral.
    const bytes = [_]u8{ 126, 128, 126, 128, 126, 128, 126, 128 };
    var fake: Fake = .{ .frame = &bytes };
    const self = try ws.Webcam.open(std.testing.allocator, fake.capture(), agreed(abi.pix_yuyv, 4), "/dev/video0");
    defer self.close();
    self.pull();
    for (0..self.image.pixels.len / 3) |index| {
        const pixel = self.image.get(index);
        try std.testing.expectEqual(pixel[0], pixel[1]);
        try std.testing.expectEqual(pixel[1], pixel[2]);
    }
}

test "the capture is black before a frame and keeps the last frame after a failed read" {
    const bytes = [_]u8{ 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF };
    var fake: Fake = .{ .frame = &bytes, .fail = true };
    const self = try ws.Webcam.open(std.testing.allocator, fake.capture(), agreed(abi.pix_rgb565, 4), "/dev/video0");
    defer self.close();
    self.pull();
    try std.testing.expectEqual(@as(u8, 0), self.image.get(0)[0]);
    fake.fail = false;
    self.pull();
    try std.testing.expectEqual(@as(u8, 255), self.image.get(0)[0]);
    fake.fail = true;
    self.pull();
    try std.testing.expectEqual(@as(u8, 255), self.image.get(3)[2]);
    try std.testing.expectEqual(@as(u64, 1), self.frames);
}

test "formats it cannot decode and rows narrower than the width are refused" {
    var fake: Fake = .{ .frame = &.{} };
    try std.testing.expectError(error.UnsupportedFormat, ws.Webcam.open(std.testing.allocator, fake.capture(), agreed(abi.fourcc("MJPG"), 4), "/dev/video0"));
    try std.testing.expectError(error.BadGeometry, ws.Webcam.open(std.testing.allocator, fake.capture(), agreed(abi.pix_yuyv, 2), "/dev/video0"));
    try std.testing.expectEqual(ra8.host.camera.webcam.input.rawFormat(abi.pix_yuyv).?, .yuyv);
}
