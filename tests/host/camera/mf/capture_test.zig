//! Covers src/host/camera/mf_capture.zig against fake reader, sample and
//! buffer objects: YUY2 copied through, RGB32 turned into RGB24, gaps
//! waited through, the end of the stream and short frames as failed reads,
//! and every sample and buffer released.
const std = @import("std");
const ra8 = @import("ra8");
const webcam = ra8.host.camera.webcam;
const mf = webcam.mf;
const mf_open = webcam.mf_open;
const mf_capture = webcam.mf_capture;

const Fake = extern struct { vtable: [*]const ?*const anyopaque };

var objects: [8]Fake = undefined;
var made: usize = 0;
var live: i32 = 0;
var gaps: u32 = 0;
var ended = false;
var frame: []const u8 = &.{};
var stopped = false;
const table = vtable();

fn reset(bytes: []const u8) void {
    made = 0;
    live = 0;
    gaps = 0;
    ended = false;
    frame = bytes;
    stopped = false;
}

fn make() *anyopaque {
    objects[made] = .{ .vtable = &table };
    made += 1;
    live += 1;
    return &objects[made - 1];
}

fn release(_: *anyopaque) callconv(mf.cc) u32 {
    live -= 1;
    return 0;
}

fn readSample(_: *anyopaque, _: u32, _: u32, _: ?*u32, flags: *u32, _: ?*i64, out: *?*anyopaque) callconv(mf.cc) mf.HRESULT {
    flags.* = if (ended) mf.end_of_stream else 0;
    if (ended or gaps > 0) {
        if (gaps > 0) gaps -= 1;
        out.* = null;
        return 0;
    }
    out.* = make();
    return 0;
}

fn toContiguous(_: *anyopaque, out: *?*anyopaque) callconv(mf.cc) mf.HRESULT {
    out.* = make();
    return 0;
}

fn lock(_: *anyopaque, bytes: *?[*]u8, _: ?*u32, length: *u32) callconv(mf.cc) mf.HRESULT {
    bytes.* = @constCast(frame.ptr);
    length.* = @intCast(frame.len);
    return 0;
}

fn unlock(_: *anyopaque) callconv(mf.cc) mf.HRESULT {
    return 0;
}

fn shutdown(_: *anyopaque) callconv(mf.cc) mf.HRESULT {
    return 0;
}

fn vtable() [42]?*const anyopaque {
    var entries: [42]?*const anyopaque = @splat(null);
    entries[mf.slot.release] = @ptrCast(&release);
    entries[mf.slot.reader_read_sample] = @ptrCast(&readSample);
    entries[mf.slot.sample_to_contiguous] = @ptrCast(&toContiguous);
    entries[mf.slot.buffer_lock] = @ptrCast(&lock);
    entries[mf.slot.buffer_unlock] = @ptrCast(&unlock);
    entries[mf.slot.shutdown_object] = @ptrCast(&shutdown);
    return entries;
}

fn ok() mf.HRESULT {
    return 0;
}

fn stop() void {
    stopped = true;
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

const calls = mf_open.Calls{ .startup = ok, .shutdown = stop, .create_attributes = none, .create_media_type = none, .enum_devices = noDevices, .create_reader = noReader, .free = free };

fn open(subtype: mf_open.Subtype) !*mf_capture.MfCapture {
    const reader = mf_open.Reader{ .calls = calls, .reader = make(), .activator = make(), .subtype = subtype, .width = 2, .height = 1 };
    return mf_capture.MfCapture.create(std.testing.allocator, reader);
}

test "YUY2 frames are copied through as YUYV" {
    reset(&.{ 10, 20, 30, 40 });
    const self = try open(.yuy2);
    const agreed = self.agreed();
    try std.testing.expectEqual(webcam.v4l2.pix_yuyv, agreed.pixelformat);
    try std.testing.expectEqual(@as(u32, 4), agreed.bytesperline);
    var out: [4]u8 = undefined;
    const cap = self.capture();
    try std.testing.expect(cap.readFn(cap.ctx, &out));
    try std.testing.expectEqualSlices(u8, &.{ 10, 20, 30, 40 }, &out);
    try std.testing.expectEqual(@as(i32, 2), live);
    cap.closeFn(cap.ctx);
    try std.testing.expectEqual(@as(i32, 0), live);
    try std.testing.expect(stopped);
}

test "RGB32 frames become RGB24 after waiting through gaps" {
    reset(&.{ 3, 2, 1, 0, 6, 5, 4, 0 });
    gaps = mf_capture.gap_tries - 1;
    const self = try open(.rgb32);
    try std.testing.expectEqual(webcam.v4l2.pix_rgb24, self.agreed().pixelformat);
    try std.testing.expectEqual(ra8.host.camera.webcam.input.rawFormat(webcam.v4l2.pix_rgb24).?, .rgb24);
    var out: [6]u8 = undefined;
    const cap = self.capture();
    try std.testing.expect(cap.readFn(cap.ctx, &out));
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4, 5, 6 }, &out);
    cap.closeFn(cap.ctx);
    try std.testing.expectEqual(@as(i32, 0), live);
}

test "the end of the stream, endless gaps and short frames are failed reads" {
    var out: [4]u8 = undefined;
    reset(&.{ 1, 2, 3, 4 });
    ended = true;
    var self = try open(.yuy2);
    var cap = self.capture();
    try std.testing.expect(!cap.readFn(cap.ctx, &out));
    ended = false;
    gaps = mf_capture.gap_tries;
    try std.testing.expect(!cap.readFn(cap.ctx, &out));
    frame = &.{ 1, 2 };
    try std.testing.expect(!cap.readFn(cap.ctx, &out));
    cap.closeFn(cap.ctx);
    try std.testing.expectEqual(@as(i32, 0), live);
    self = undefined;
}
