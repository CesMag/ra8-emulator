//! Covers src/host/camera/av_permission.zig with a fake Objective-C
//! runtime: the status read, the verdict mapping, and the gate's messages.
const std = @import("std");
const ra8 = @import("ra8");
const av = ra8.host.camera.av_permission;

var device_class: u8 = 0;
var status_selector: u8 = 0;
var video_string: u8 = 0;
var answer: isize = 3;
var has_class = true;

fn class(name: [*:0]const u8) callconv(.c) ?*anyopaque {
    if (!has_class or !std.mem.eql(u8, std.mem.span(name), "AVCaptureDevice")) return null;
    return &device_class;
}

fn selector(name: [*:0]const u8) callconv(.c) ?*anyopaque {
    if (!std.mem.eql(u8, std.mem.span(name), "authorizationStatusForMediaType:")) return null;
    return &status_selector;
}

fn send(target: *anyopaque, select: *anyopaque, media: *anyopaque) callconv(.c) isize {
    if (target != @as(*anyopaque, &device_class) or select != @as(*anyopaque, &status_selector) or media != @as(*anyopaque, &video_string)) return -1;
    return answer;
}

fn runtime() av.Runtime {
    return .{ .class = class, .selector = selector, .send = send, .video = &video_string };
}

test "the status comes from authorizationStatusForMediaType: on AVCaptureDevice" {
    has_class = true;
    answer = 2;
    try std.testing.expectEqual(av.Status.denied, av.status(runtime()));
    answer = 3;
    try std.testing.expectEqual(av.Status.authorized, av.status(runtime()));
}

test "a missing class or media type reads as not asked" {
    has_class = false;
    try std.testing.expectEqual(av.Status.not_determined, av.status(runtime()));
    has_class = true;
    var no_video = runtime();
    no_video.video = null;
    try std.testing.expectEqual(av.Status.not_determined, av.status(no_video));
}

test "denied and restricted block; authorized and not asked pass" {
    try std.testing.expectEqual(ra8.host.camera.privacy.Verdict.denied, av.verdict(.restricted));
    try std.testing.expectEqual(ra8.host.camera.privacy.Verdict.allowed, av.verdict(.authorized));
    try std.testing.expectEqual(ra8.host.camera.privacy.Verdict.unset, av.verdict(.not_determined));
    var said: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer said.deinit();
    try av.gate(.authorized, &said.writer);
    try av.gate(.not_determined, &said.writer);
    try std.testing.expectEqual(@as(usize, 0), said.written().len);
    try std.testing.expectError(error.PrivacyBlocked, av.gate(.denied, &said.writer));
    try std.testing.expect(std.mem.indexOf(u8, said.written(), "Privacy & Security > Camera") != null);
    try std.testing.expectError(error.PrivacyBlocked, av.gate(.restricted, &said.writer));
    try std.testing.expect(std.mem.indexOf(u8, said.written(), "Screen Time") != null);
}

test "hosts other than macOS read as not asked" {
    if (@import("builtin").os.tag == .macos) return error.SkipZigTest;
    try std.testing.expectEqual(av.Status.not_determined, av.host());
}
