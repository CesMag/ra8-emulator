//! The Objective-C runtime the macOS capture drives (RA8EMU-502), opened
//! at run time so builds and cross builds need no macOS SDK. `send*` cast
//! the one objc_msgSend to the shape each message needs. `delegateClass`
//! registers Ra8CaptureDelegate, an NSObject whose
//! captureOutput:didOutputSampleBuffer:fromConnection: is av_delegate's
//! didOutput; a later open finds the class already there and reuses it.
const std = @import("std");
const builtin = @import("builtin");
const delegate = @import("delegate.zig");

pub const Id = ?*anyopaque;
pub const Imp = *const fn (Id, Id, Id, Id, Id) callconv(.c) void;

pub const Runtime = struct {
    class: *const fn ([*:0]const u8) callconv(.c) Id,
    selector: *const fn ([*:0]const u8) callconv(.c) Id,
    msg_send: *const anyopaque,
    allocate_class: *const fn (Id, [*:0]const u8, usize) callconv(.c) Id,
    add_method: *const fn (Id, Id, Imp, [*:0]const u8) callconv(.c) u8,
    register_class: *const fn (Id) callconv(.c) void,
    dispose_class: *const fn (Id) callconv(.c) void,
};

pub fn send0(rt: Runtime, comptime R: type, recv: Id, sel: [*:0]const u8) R {
    const F = *const fn (Id, Id) callconv(.c) R;
    const f: F = @ptrCast(@alignCast(rt.msg_send));
    return f(recv, rt.selector(sel));
}

pub fn send1(rt: Runtime, comptime R: type, recv: Id, sel: [*:0]const u8, a: anytype) R {
    const F = *const fn (Id, Id, @TypeOf(a)) callconv(.c) R;
    const f: F = @ptrCast(@alignCast(rt.msg_send));
    return f(recv, rt.selector(sel), a);
}

pub fn send2(rt: Runtime, comptime R: type, recv: Id, sel: [*:0]const u8, a: anytype, b: anytype) R {
    const F = *const fn (Id, Id, @TypeOf(a), @TypeOf(b)) callconv(.c) R;
    const f: F = @ptrCast(@alignCast(rt.msg_send));
    return f(recv, rt.selector(sel), a, b);
}

/// [[cls alloc] init], or null when the class is missing or init refuses.
pub fn new(rt: Runtime, class_name: [*:0]const u8) Id {
    const cls = rt.class(class_name) orelse return null;
    const made = send0(rt, Id, cls, "alloc") orelse return null;
    return send0(rt, Id, made, "init");
}

pub const delegate_class = "Ra8CaptureDelegate";
pub const delegate_selector = "captureOutput:didOutputSampleBuffer:fromConnection:";
pub const delegate_types = "v@:@@@";

/// The delegate class, registered on first use; null when NSObject or the
/// selector is missing or the method won't attach.
pub fn delegateClass(rt: Runtime) Id {
    if (rt.class(delegate_class)) |cls| return cls;
    const base = rt.class("NSObject") orelse return null;
    const sel = rt.selector(delegate_selector) orelse return null;
    const cls = rt.allocate_class(base, delegate_class, 0) orelse return null;
    if (rt.add_method(cls, sel, delegate.didOutput, delegate_types) == 0) {
        rt.dispose_class(cls);
        return null;
    }
    rt.register_class(cls);
    return cls;
}

pub const objc_path = "/usr/lib/libobjc.A.dylib";

/// This Mac's runtime; null off macOS or when a call is missing. The
/// library stays loaded for the life of the process.
pub fn host() ?Runtime {
    if (builtin.os.tag != .macos) return null;
    var lib = std.DynLib.open(objc_path) catch return null;
    return .{
        .class = lib.lookup(@FieldType(Runtime, "class"), "objc_getClass") orelse return null,
        .selector = lib.lookup(@FieldType(Runtime, "selector"), "sel_registerName") orelse return null,
        .msg_send = lib.lookup(*const anyopaque, "objc_msgSend") orelse return null,
        .allocate_class = lib.lookup(@FieldType(Runtime, "allocate_class"), "objc_allocateClassPair") orelse return null,
        .add_method = lib.lookup(@FieldType(Runtime, "add_method"), "class_addMethod") orelse return null,
        .register_class = lib.lookup(@FieldType(Runtime, "register_class"), "objc_registerClassPair") orelse return null,
        .dispose_class = lib.lookup(@FieldType(Runtime, "dispose_class"), "objc_disposeClassPair") orelse return null,
    };
}
