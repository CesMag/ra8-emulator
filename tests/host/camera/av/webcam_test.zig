//! Covers src/host/camera/av/webcam.zig against a fake Objective-C
//! runtime: device indexes, a refusal that never touches AVFoundation, a
//! denied permission reported plainly, and an open that runs the session,
//! reads as YUYV 640x480, and stops and releases it on close.
const std = @import("std");
const ra8 = @import("ra8");
const webcam = ra8.host.camera.webcam;
const av_webcam = webcam.av_webcam;
const objc = webcam.av_objc;
const Id = objc.Id;

const allocator = std.testing.allocator;
var objects: [4]u8 = undefined;
var queue: u8 = 0;
var sends: usize = 0;
var stops: usize = 0;
var releases: usize = 0;
var device_count: usize = 1;

fn reset() void {
    sends = 0;
    stops = 0;
    releases = 0;
    device_count = 1;
}

fn class(_: [*:0]const u8) callconv(.c) Id {
    return &objects[0];
}
fn selector(name: [*:0]const u8) callconv(.c) Id {
    return @ptrCast(@constCast(name));
}
fn msgSend(_: Id, sel: Id, _: usize, _: usize) callconv(.c) usize {
    const name = std.mem.span(@as([*:0]const u8, @ptrCast(sel.?)));
    sends += 1;
    if (std.mem.eql(u8, name, "stopRunning")) stops += 1;
    if (std.mem.eql(u8, name, "release")) releases += 1;
    if (std.mem.eql(u8, name, "count")) return device_count;
    if (std.mem.startsWith(u8, name, "can")) return 1;
    return @intFromPtr(&objects[1]);
}
fn allocate(_: Id, _: [*:0]const u8, _: usize) callconv(.c) Id {
    return &objects[2];
}
fn addMethod(_: Id, _: Id, _: objc.Imp, _: [*:0]const u8) callconv(.c) u8 {
    return 1;
}
fn noop(_: Id) callconv(.c) void {}
fn queueCreate(_: [*:0]const u8, _: Id) callconv(.c) Id {
    return &queue;
}

fn host(answer: webcam.av_permission.Status) av_webcam.Host {
    return .{
        .rt = .{ .class = class, .selector = selector, .msg_send = @ptrCast(&msgSend), .allocate_class = allocate, .add_method = addMethod, .register_class = noop, .dispose_class = noop },
        .media = undefined,
        .syms = .{ .video = &objects[3], .preset = &objects[3], .format_key = &objects[3], .queue_create = queueCreate },
        .permission = answer,
    };
}

fn openAnswering(answer: webcam.av_permission.Status, arg: []const u8, grant: webcam.consent.Grant, typed: []const u8, said: *std.Io.Writer.Allocating) !*webcam.input.Webcam {
    var in = std.Io.Reader.fixed(typed);
    return av_webcam.openWith(allocator, host(answer), arg, grant, &in, &said.writer);
}

test "webcam args name a device index; paths are not macOS devices" {
    try std.testing.expectEqual(@as(?u32, 0), av_webcam.index(""));
    try std.testing.expectEqual(@as(?u32, 2), av_webcam.index("2"));
    try std.testing.expectEqual(@as(?u32, null), av_webcam.index("/dev/video0"));
    const agreed = av_webcam.agreed();
    try std.testing.expectEqual(webcam.v4l2.pix_yuyv, agreed.pixelformat);
    try std.testing.expectEqual(@as(u32, 640 * 2 * 480), agreed.sizeimage);
}

test "a refusal asks about webcam N and never touches AVFoundation" {
    reset();
    var said = std.Io.Writer.Allocating.init(allocator);
    defer said.deinit();
    try std.testing.expectError(error.WebcamRefused, openAnswering(.authorized, "1", .ask, "n\n", &said));
    try std.testing.expect(std.mem.indexOf(u8, said.written(), "webcam 1") != null);
    try std.testing.expectEqual(@as(usize, 0), sends);
}

test "a denied permission says where to fix it and opens nothing" {
    reset();
    var said = std.Io.Writer.Allocating.init(allocator);
    defer said.deinit();
    try std.testing.expectError(error.PrivacyBlocked, openAnswering(.denied, "", .allowed, "", &said));
    try std.testing.expect(std.mem.indexOf(u8, said.written(), "Privacy & Security") != null);
    try std.testing.expectEqual(@as(usize, 0), sends);
}

test "no camera returns cleanly and frees the partial capture" {
    reset();
    device_count = 0;
    var said = std.Io.Writer.Allocating.init(allocator);
    defer said.deinit();
    try std.testing.expectError(error.NoDevice, openAnswering(.authorized, "", .allowed, "", &said));
    try std.testing.expectEqual(@as(usize, 0), stops);
    try std.testing.expectEqual(@as(usize, 0), releases);
}

test "an allowed open runs the session and close stops and releases it" {
    reset();
    var said = std.Io.Writer.Allocating.init(allocator);
    defer said.deinit();
    const camera = try openAnswering(.authorized, "0", .allowed, "", &said);
    try std.testing.expect(sends > 0);
    camera.close();
    try std.testing.expectEqual(@as(usize, 1), stops);
    try std.testing.expectEqual(@as(usize, 5), releases);
}
