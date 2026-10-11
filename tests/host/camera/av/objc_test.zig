//! Covers src/host/camera/av_objc.zig against a fake runtime: typed
//! sends reach objc_msgSend with the right selector and arguments, `new`
//! is alloc then init, and the delegate class is registered once with
//! didOutput, reused later, and disposed when the method won't attach.
const std = @import("std");
const ra8 = @import("ra8");
const webcam = ra8.host.camera;
const objc = webcam.av_objc;
const Id = objc.Id;

var object: u8 = 0;
var nsobject: u8 = 0;
var made_class: u8 = 0;
var registered = false;
var has_nsobject = true;
var add_ok: u8 = 1;
var allocs: u32 = 0;
var disposed: u32 = 0;
var added_imp: ?objc.Imp = null;
var added_types: []const u8 = "";
var last_sel: []const u8 = "";
var last_arg: usize = 0;

fn reset() void {
    registered = false;
    has_nsobject = true;
    add_ok = 1;
    allocs = 0;
    disposed = 0;
    added_imp = null;
}

fn class(name: [*:0]const u8) callconv(.c) Id {
    const text = std.mem.span(name);
    if (std.mem.eql(u8, text, "NSObject")) return if (has_nsobject) &nsobject else null;
    if (std.mem.eql(u8, text, objc.delegate_class)) return if (registered) &made_class else null;
    if (std.mem.eql(u8, text, "Thing")) return &object;
    return null;
}
fn selector(name: [*:0]const u8) callconv(.c) Id {
    return @ptrCast(@constCast(name));
}
fn msgSend(_: Id, sel: Id, arg: usize) callconv(.c) Id {
    last_sel = std.mem.span(@as([*:0]const u8, @ptrCast(sel.?)));
    last_arg = arg;
    return &object;
}
fn allocate(_: Id, _: [*:0]const u8, _: usize) callconv(.c) Id {
    allocs += 1;
    return &made_class;
}
fn addMethod(_: Id, _: Id, imp: objc.Imp, types: [*:0]const u8) callconv(.c) u8 {
    added_imp = imp;
    added_types = std.mem.span(types);
    return add_ok;
}
fn register(_: Id) callconv(.c) void {
    registered = true;
}
fn dispose(_: Id) callconv(.c) void {
    disposed += 1;
}

const rt: objc.Runtime = .{ .class = class, .selector = selector, .msg_send = @ptrCast(&msgSend), .allocate_class = allocate, .add_method = addMethod, .register_class = register, .dispose_class = dispose };

test "a typed send passes the selector and argument" {
    try std.testing.expectEqual(@as(Id, &object), objc.send1(rt, Id, &object, "objectAtIndex:", @as(usize, 3)));
    try std.testing.expectEqualStrings("objectAtIndex:", last_sel);
    try std.testing.expectEqual(@as(usize, 3), last_arg);
}

test "new is alloc then init, and a missing class is null" {
    try std.testing.expectEqual(@as(Id, &object), objc.new(rt, "Thing"));
    try std.testing.expectEqualStrings("init", last_sel);
    try std.testing.expect(objc.new(rt, "Missing") == null);
}

test "the delegate class is registered once with didOutput" {
    reset();
    try std.testing.expectEqual(@as(Id, &made_class), objc.delegateClass(rt));
    try std.testing.expect(added_imp.? == webcam.av_delegate.didOutput);
    try std.testing.expectEqualStrings("v@:@@@", added_types);
    try std.testing.expectEqual(@as(Id, &made_class), objc.delegateClass(rt));
    try std.testing.expectEqual(@as(u32, 1), allocs);
}

test "a refused method disposes the class; no NSObject is null" {
    reset();
    add_ok = 0;
    try std.testing.expect(objc.delegateClass(rt) == null);
    try std.testing.expectEqual(@as(u32, 1), disposed);
    try std.testing.expect(!registered);
    reset();
    has_nsobject = false;
    try std.testing.expect(objc.delegateClass(rt) == null);
    try std.testing.expectEqual(@as(u32, 0), allocs);
}

test "off macOS there is no runtime" {
    if (@import("builtin").os.tag == .macos) return error.SkipZigTest;
    try std.testing.expect(objc.host() == null);
}
