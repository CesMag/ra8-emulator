//! The macOS camera permission (RA8EMU-502). AVFoundation keeps one answer
//! per app under System Settings > Privacy & Security > Camera; a denied or
//! restricted answer makes capture hand back nothing, so the webcam opener
//! reads it first and says how to fix it. The Objective-C runtime and
//! AVFoundation are loaded with dlopen at run time, so the emulator builds
//! and cross-compiles without a macOS SDK, and the lookups sit behind
//! `Runtime` so the mapping runs against fakes on any host.
const std = @import("std");
const builtin = @import("builtin");
const privacy = @import("webcam/privacy.zig");

/// AVAuthorizationStatus.
pub const Status = enum(isize) { not_determined = 0, restricted = 1, denied = 2, authorized = 3, _ };

pub const denied_message = "webcam blocked by macOS privacy settings: allow your terminal (or ra8_emulator) under System Settings > Privacy & Security > Camera, then run again";
pub const restricted_message = "webcam restricted on this Mac: Screen Time or a device management profile blocks the camera";

/// Not yet asked is not a refusal: macOS asks when capture starts.
pub fn verdict(answer: Status) privacy.Verdict {
    return switch (answer) {
        .authorized => .allowed,
        .denied, .restricted => .denied,
        else => .unset,
    };
}

/// Refuses, with the fix on `writer`, when the permission blocks the camera.
pub fn gate(answer: Status, writer: anytype) privacy.Error!void {
    const message = switch (answer) {
        .denied => denied_message,
        .restricted => restricted_message,
        else => return,
    };
    writer.print("{s}\n", .{message}) catch {};
    return error.PrivacyBlocked;
}

pub const ClassFn = *const fn ([*:0]const u8) callconv(.c) ?*anyopaque;
pub const SelectorFn = *const fn ([*:0]const u8) callconv(.c) ?*anyopaque;
/// objc_msgSend typed for +[AVCaptureDevice authorizationStatusForMediaType:].
pub const StatusSendFn = *const fn (*anyopaque, *anyopaque, *anyopaque) callconv(.c) isize;

/// The three runtime calls and the AVMediaTypeVideo string the read needs.
pub const Runtime = struct {
    class: ClassFn,
    selector: SelectorFn,
    send: StatusSendFn,
    video: ?*anyopaque,
};

/// The permission as `runtime` reports it; anything missing reads as not asked.
pub fn status(runtime: Runtime) Status {
    const device = runtime.class("AVCaptureDevice") orelse return .not_determined;
    const select = runtime.selector("authorizationStatusForMediaType:") orelse return .not_determined;
    const video = runtime.video orelse return .not_determined;
    return @fromBackingInt(@intCast(runtime.send(device, select, video)));
}

pub const objc_path = "/usr/lib/libobjc.A.dylib";
pub const avfoundation_path = "/System/Library/Frameworks/AVFoundation.framework/AVFoundation";

/// This Mac's answer; not asked off macOS or when a library is missing.
/// The libraries stay loaded: the capture uses them next.
pub fn host() Status {
    if (builtin.os.tag != .macos) return .not_determined;
    var objc = std.DynLib.open(objc_path) catch return .not_determined;
    var av = std.DynLib.open(avfoundation_path) catch return .not_determined;
    const video = av.lookup(*const ?*anyopaque, "AVMediaTypeVideo") orelse return .not_determined;
    return status(.{
        .class = objc.lookup(ClassFn, "objc_getClass") orelse return .not_determined,
        .selector = objc.lookup(SelectorFn, "sel_registerName") orelse return .not_determined,
        .send = objc.lookup(StatusSendFn, "objc_msgSend") orelse return .not_determined,
        .video = video.*,
    });
}
