//! Covers src/host/camera/av_frame.zig: CoreVideo formats, the 2vuy
//! swizzle and BGRA to RGB24 with row padding, short buffers, and the
//! newest-frame mailbox.
const std = @import("std");
const ra8 = @import("ra8");
const webcam = ra8.host.camera;
const frame = webcam.av_frame;
const v4l2 = webcam.v4l2;

test "CoreVideo formats map to what the webcam input decodes" {
    try std.testing.expectEqual(frame.Pixel.uyvy, frame.pixelOf(frame.cv_2vuy).?);
    try std.testing.expectEqual(frame.Pixel.bgra, frame.pixelOf(frame.cv_bgra).?);
    try std.testing.expect(frame.pixelOf(0x3432_3076) == null);
    try std.testing.expectEqual(v4l2.pix_yuyv, frame.pixelformat(.uyvy));
    try std.testing.expectEqual(v4l2.pix_rgb24, frame.pixelformat(.bgra));
}

test "2vuy rows become YUYV and the padding is skipped" {
    // 2x2, stride 6: U Y0 V Y1 then two pad bytes per row.
    const src = [_]u8{ 1, 2, 3, 4, 0xEE, 0xEE, 5, 6, 7, 8, 0xEE, 0xEE };
    var out: [8]u8 = undefined;
    try std.testing.expect(frame.copy(.uyvy, &src, 6, 2, 2, &out));
    try std.testing.expectEqualSlices(u8, &.{ 2, 1, 4, 3, 6, 5, 8, 7 }, &out);
}

test "BGRA rows become RGB24" {
    const src = [_]u8{ 10, 20, 30, 255, 40, 50, 60, 255 };
    var out: [6]u8 = undefined;
    try std.testing.expect(frame.copy(.bgra, &src, 8, 2, 1, &out));
    try std.testing.expectEqualSlices(u8, &.{ 30, 20, 10, 60, 50, 40 }, &out);
}

test "short buffers, odd 2vuy widths and thin strides are refused" {
    var out: [16]u8 = undefined;
    const src = @as([8]u8, @splat(0));
    try std.testing.expect(!frame.copy(.bgra, &src, 8, 2, 2, &out));
    try std.testing.expect(!frame.copy(.uyvy, &src, 6, 3, 1, &out));
    try std.testing.expect(!frame.copy(.bgra, &src, 4, 2, 1, &out));
    try std.testing.expect(!frame.copy(.bgra, &src, 8, 2, 1, out[0..5]));
    try std.testing.expect(!frame.copy(.bgra, &src, 8, 0, 1, &out));
}

test "the mailbox hands the newest frame out once" {
    var box = try frame.Mailbox.init(std.testing.allocator, .bgra, 1, 1);
    defer box.deinit();
    var out: [3]u8 = undefined;
    try std.testing.expect(!box.take(&out));
    try std.testing.expect(box.put(&.{ 1, 2, 3, 0 }, 4, 1, 1));
    try std.testing.expect(box.put(&.{ 4, 5, 6, 0 }, 4, 1, 1));
    try std.testing.expect(box.take(&out));
    try std.testing.expectEqualSlices(u8, &.{ 6, 5, 4 }, &out);
    try std.testing.expect(!box.take(&out));
}

test "the mailbox drops a buffer of another size" {
    var box = try frame.Mailbox.init(std.testing.allocator, .bgra, 1, 1);
    defer box.deinit();
    var out: [3]u8 = undefined;
    try std.testing.expect(!box.put(&.{ 1, 2, 3, 0, 1, 2, 3, 0 }, 8, 2, 1));
    try std.testing.expect(!box.take(&out));
}
