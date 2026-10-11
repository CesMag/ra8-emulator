//! The macOS capture delegate's body (RA8EMU-502). AVFoundation calls
//! captureOutput:didOutputSampleBuffer:fromConnection: on its dispatch
//! queue with a CMSampleBuffer; `didOutput` is that method's IMP. It takes
//! the sample's CVPixelBuffer, locks it read-only, and puts the bytes in the
//! active sink's Mailbox. A sample in another pixel format, one that won't
//! lock, or one with no base address is counted as dropped.
//!
//! One webcam runs at a time, so the active sink is one process-wide
//! pointer. The session must stop (stopRunning returns once the queue has
//! no callback in flight) before `detach`, so a callback never sees a sink
//! that is gone.
const std = @import("std");
const builtin = @import("builtin");
const frame = @import("frame.zig");

pub const lock_read_only: u64 = 1; // kCVPixelBufferLock_ReadOnly

/// The CoreMedia and CoreVideo calls a sample needs.
pub const Media = struct {
    image_buffer: *const fn (?*anyopaque) callconv(.c) ?*anyopaque,
    lock: *const fn (?*anyopaque, u64) callconv(.c) i32,
    unlock: *const fn (?*anyopaque, u64) callconv(.c) i32,
    base: *const fn (?*anyopaque) callconv(.c) ?[*]const u8,
    stride: *const fn (?*anyopaque) callconv(.c) usize,
    width: *const fn (?*anyopaque) callconv(.c) usize,
    height: *const fn (?*anyopaque) callconv(.c) usize,
    os_type: *const fn (?*anyopaque) callconv(.c) u32,
};

pub const Sink = struct {
    media: Media,
    box: *frame.Mailbox,
    kept: std.atomic.Value(u32) = .init(0),
    dropped: std.atomic.Value(u32) = .init(0),
};

var active: std.atomic.Value(?*Sink) = .init(null);

pub fn attach(sink: *Sink) void {
    active.store(sink, .release);
}

pub fn detach() void {
    active.store(null, .release);
}

/// One sample into `sink`; true when it became the newest frame.
pub fn onSample(sink: *Sink, sample: ?*anyopaque) bool {
    const kept = keep(sink.media, sink.box, sample);
    _ = if (kept) sink.kept.fetchAdd(1, .monotonic) else sink.dropped.fetchAdd(1, .monotonic);
    return kept;
}

fn keep(media: Media, box: *frame.Mailbox, sample: ?*anyopaque) bool {
    const buffer = media.image_buffer(sample) orelse return false;
    if (frame.pixelOf(media.os_type(buffer)) != box.pixel) return false;
    if (media.lock(buffer, lock_read_only) != 0) return false;
    defer _ = media.unlock(buffer, lock_read_only);
    const base = media.base(buffer) orelse return false;
    const stride = media.stride(buffer);
    const height = media.height(buffer);
    return box.put(base[0 .. stride * height], stride, media.width(buffer), height);
}

/// The delegate method's IMP: (self, _cmd, output, sample, connection).
pub fn didOutput(_: ?*anyopaque, _: ?*anyopaque, _: ?*anyopaque, sample: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
    const sink = active.load(.acquire) orelse return;
    _ = onSample(sink, sample);
}

pub const coremedia_path = "/System/Library/Frameworks/CoreMedia.framework/CoreMedia";
pub const corevideo_path = "/System/Library/Frameworks/CoreVideo.framework/CoreVideo";

/// This Mac's CoreMedia and CoreVideo; null off macOS or when one is
/// missing. The libraries stay loaded for the life of the process.
pub fn host() ?Media {
    if (builtin.os.tag != .macos) return null;
    var cm = std.DynLib.open(coremedia_path) catch return null;
    var cv = std.DynLib.open(corevideo_path) catch return null;
    return .{
        .image_buffer = cm.lookup(@FieldType(Media, "image_buffer"), "CMSampleBufferGetImageBuffer") orelse return null,
        .lock = cv.lookup(@FieldType(Media, "lock"), "CVPixelBufferLockBaseAddress") orelse return null,
        .unlock = cv.lookup(@FieldType(Media, "unlock"), "CVPixelBufferUnlockBaseAddress") orelse return null,
        .base = cv.lookup(@FieldType(Media, "base"), "CVPixelBufferGetBaseAddress") orelse return null,
        .stride = cv.lookup(@FieldType(Media, "stride"), "CVPixelBufferGetBytesPerRow") orelse return null,
        .width = cv.lookup(@FieldType(Media, "width"), "CVPixelBufferGetWidth") orelse return null,
        .height = cv.lookup(@FieldType(Media, "height"), "CVPixelBufferGetHeight") orelse return null,
        .os_type = cv.lookup(@FieldType(Media, "os_type"), "CVPixelBufferGetPixelFormatType") orelse return null,
    };
}
