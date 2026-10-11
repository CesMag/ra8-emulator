//! Covers src/host/camera/av_delegate.zig against fake CoreMedia and
//! CoreVideo calls: a good sample lands in the mailbox and is unlocked,
//! other formats, lock failures, missing buffers and base addresses are
//! dropped, and the IMP only feeds an attached sink.
const std = @import("std");
const ra8 = @import("ra8");
const webcam = ra8.host.camera;
const delegate = webcam.av_delegate;
const frame = webcam.av_frame;

var pixels = [_]u8{ 10, 20, 30, 255, 0xEE, 0xEE, 0xEE, 0xEE };
var fake_buffer: u8 = 0;
var has_buffer = true;
var has_base = true;
var lock_result: i32 = 0;
var os_type: u32 = frame.cv_bgra;
var locks: u32 = 0;
var unlocks: u32 = 0;

fn reset() void {
    has_buffer = true;
    has_base = true;
    lock_result = 0;
    os_type = frame.cv_bgra;
    locks = 0;
    unlocks = 0;
}

fn imageBuffer(_: ?*anyopaque) callconv(.c) ?*anyopaque {
    return if (has_buffer) &fake_buffer else null;
}
fn lock(_: ?*anyopaque, flags: u64) callconv(.c) i32 {
    std.debug.assert(flags == delegate.lock_read_only);
    locks += 1;
    return lock_result;
}
fn unlock(_: ?*anyopaque, _: u64) callconv(.c) i32 {
    unlocks += 1;
    return 0;
}
fn base(_: ?*anyopaque) callconv(.c) ?[*]const u8 {
    return if (has_base) &pixels else null;
}
fn stride(_: ?*anyopaque) callconv(.c) usize {
    return 8;
}
fn one(_: ?*anyopaque) callconv(.c) usize {
    return 1;
}
fn osType(_: ?*anyopaque) callconv(.c) u32 {
    return os_type;
}

const media: delegate.Media = .{ .image_buffer = imageBuffer, .lock = lock, .unlock = unlock, .base = base, .stride = stride, .width = one, .height = one, .os_type = osType };

test "a good sample becomes the newest frame and is unlocked" {
    reset();
    var box = try frame.Mailbox.init(std.testing.allocator, .bgra, 1, 1);
    defer box.deinit();
    var sink: delegate.Sink = .{ .media = media, .box = &box };
    try std.testing.expect(delegate.onSample(&sink, null));
    var out: [3]u8 = undefined;
    try std.testing.expect(box.take(&out));
    try std.testing.expectEqualSlices(u8, &.{ 30, 20, 10 }, &out);
    try std.testing.expectEqual(@as(u32, 1), locks);
    try std.testing.expectEqual(@as(u32, 1), unlocks);
    try std.testing.expectEqual(@as(u32, 1), sink.kept.load(.monotonic));
}

test "unusable samples are dropped and never left locked" {
    reset();
    var box = try frame.Mailbox.init(std.testing.allocator, .bgra, 1, 1);
    defer box.deinit();
    var sink: delegate.Sink = .{ .media = media, .box = &box };
    has_buffer = false;
    try std.testing.expect(!delegate.onSample(&sink, null));
    has_buffer = true;
    os_type = frame.cv_2vuy;
    try std.testing.expect(!delegate.onSample(&sink, null));
    os_type = frame.cv_bgra;
    lock_result = -6660;
    try std.testing.expect(!delegate.onSample(&sink, null));
    lock_result = 0;
    has_base = false;
    try std.testing.expect(!delegate.onSample(&sink, null));
    try std.testing.expectEqual(@as(u32, 4), sink.dropped.load(.monotonic));
    try std.testing.expectEqual(locks, unlocks + 1);
}

test "the IMP feeds only an attached sink" {
    reset();
    var box = try frame.Mailbox.init(std.testing.allocator, .bgra, 1, 1);
    defer box.deinit();
    var sink: delegate.Sink = .{ .media = media, .box = &box };
    var out: [3]u8 = undefined;
    delegate.didOutput(null, null, null, null, null);
    try std.testing.expect(!box.take(&out));
    delegate.attach(&sink);
    delegate.didOutput(null, null, null, null, null);
    delegate.detach();
    try std.testing.expect(box.take(&out));
    delegate.didOutput(null, null, null, null, null);
    try std.testing.expectEqual(@as(u32, 1), sink.kept.load(.monotonic));
}

test "off macOS there is no CoreMedia" {
    if (@import("builtin").os.tag == .macos) return error.SkipZigTest;
    try std.testing.expect(delegate.host() == null);
}
