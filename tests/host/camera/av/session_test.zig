//! Covers src/host/camera/av_session.zig against a fake Objective-C
//! runtime that logs every message: the open sequence, the preset and
//! video settings, the sink attached for the delegate, a missing device
//! index, and a refused output releasing everything it made.
const std = @import("std");
const ra8 = @import("ra8");
const webcam = ra8.host.camera;
const session = webcam.av_session;
const objc = webcam.av_objc;
const delegate = webcam.av_delegate;
const Id = objc.Id;

var objects: [8]u8 = undefined;
var log_buf: [64][]const u8 = undefined;
var log_len: usize = 0;
var device_count: usize = 1;
var refuse_output = false;
var last_u32: u32 = 0;
var queue: u8 = 0;

fn reset() void {
    log_len = 0;
    device_count = 1;
    refuse_output = false;
}

fn logged(sel: []const u8) usize {
    var n: usize = 0;
    for (log_buf[0..log_len]) |s| n += @intFromBool(std.mem.eql(u8, s, sel));
    return n;
}

fn class(_: [*:0]const u8) callconv(.c) Id {
    return &objects[0];
}
fn selector(name: [*:0]const u8) callconv(.c) Id {
    return @ptrCast(@constCast(name));
}
fn msgSend(_: Id, sel: Id, a: usize, _: usize) callconv(.c) usize {
    const name = std.mem.span(@as([*:0]const u8, @ptrCast(sel.?)));
    log_buf[log_len] = name;
    log_len += 1;
    if (std.mem.eql(u8, name, "count")) return device_count;
    if (std.mem.eql(u8, name, "numberWithUnsignedInt:")) last_u32 = @truncate(a);
    if (std.mem.eql(u8, name, "canAddOutput:")) return @intFromBool(!refuse_output);
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
fn queueCreate(label: [*:0]const u8, _: Id) callconv(.c) Id {
    std.debug.assert(std.mem.eql(u8, std.mem.span(label), session.queue_label));
    return &queue;
}

const rt: objc.Runtime = .{ .class = class, .selector = selector, .msg_send = @ptrCast(&msgSend), .allocate_class = allocate, .add_method = addMethod, .register_class = noop, .dispose_class = noop };
const syms: session.Symbols = .{ .video = &objects[3], .preset = &objects[4], .format_key = &objects[5], .queue_create = queueCreate };

fn sink(box: *webcam.av_frame.Mailbox) delegate.Sink {
    return .{ .media = undefined, .box = box };
}

test "open builds the session, asks for 2vuy and starts running" {
    reset();
    var box = try webcam.av_frame.Mailbox.init(std.testing.allocator, .uyvy, 2, 1);
    defer box.deinit();
    var s = sink(&box);
    var opened = try session.open(rt, syms, 0, &s);
    for ([_][]const u8{ "devicesWithMediaType:", "objectAtIndex:", "deviceInputWithDevice:error:", "retain", "setSessionPreset:", "addInput:", "setVideoSettings:", "setAlwaysDiscardsLateVideoFrames:", "setSampleBufferDelegate:queue:", "addOutput:", "startRunning" }) |sel|
        try std.testing.expectEqual(@as(usize, 1), logged(sel));
    try std.testing.expectEqual(webcam.av_frame.cv_2vuy, last_u32);
    try std.testing.expect(opened.running);
    opened.close();
    try std.testing.expectEqual(@as(usize, 1), logged("stopRunning"));
    try std.testing.expectEqual(@as(usize, 5), logged("release"));
}

test "an index past the last camera is NoDevice and makes nothing" {
    reset();
    device_count = 1;
    var box = try webcam.av_frame.Mailbox.init(std.testing.allocator, .uyvy, 2, 1);
    defer box.deinit();
    var s = sink(&box);
    try std.testing.expectError(error.NoDevice, session.open(rt, syms, 1, &s));
    try std.testing.expectEqual(@as(usize, 0), logged("release"));
    try std.testing.expectEqual(@as(usize, 0), logged("stopRunning"));
}

test "a refused output releases what was made and never starts" {
    reset();
    refuse_output = true;
    var box = try webcam.av_frame.Mailbox.init(std.testing.allocator, .uyvy, 2, 1);
    defer box.deinit();
    var s = sink(&box);
    try std.testing.expectError(error.NoOutput, session.open(rt, syms, 0, &s));
    try std.testing.expectEqual(@as(usize, 0), logged("startRunning"));
    try std.testing.expectEqual(@as(usize, 0), logged("stopRunning"));
    try std.testing.expectEqual(@as(usize, 5), logged("release"));
    delegate.didOutput(null, null, null, null, null);
}
