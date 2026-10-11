//! Covers src/host/camera/mf_open.zig against fake Media Foundation
//! calls and COM objects: device pick, YUY2 then RGB32, the size read
//! back, and every object released and MF stopped on each path.
const std = @import("std");
const ra8 = @import("ra8");
const mf = ra8.host.camera.mf;
const mf_open = ra8.host.camera.mf_open;

const Fake = extern struct { vtable: [*]const ?*const anyopaque };

var pool: [24]Fake = undefined;
var used: usize = 0;
var live: i32 = 0;
var started: i32 = 0;
var device_count: u32 = 2;
var refuse: enum { none, yuy2, all } = .none;
var last_subtype: mf.Guid = undefined;
var devices: [4]?*anyopaque = undefined;
const table = vtable();

fn reset() void {
    used = 0;
    live = 0;
    started = 0;
    device_count = 2;
    refuse = .none;
}

fn make() *anyopaque {
    pool[used] = .{ .vtable = &table };
    used += 1;
    live += 1;
    return &pool[used - 1];
}

fn release(_: *anyopaque) callconv(mf.cc) u32 {
    live -= 1;
    return 0;
}

fn setGuid(_: *anyopaque, key: *const mf.Guid, value: *const mf.Guid) callconv(mf.cc) mf.HRESULT {
    if (std.meta.eql(key.*, mf.mt_subtype)) last_subtype = value.*;
    return 0;
}

fn setUint32(_: *anyopaque, _: *const mf.Guid, _: u32) callconv(mf.cc) mf.HRESULT {
    return 0;
}

fn setUint64(_: *anyopaque, _: *const mf.Guid, _: u64) callconv(mf.cc) mf.HRESULT {
    return 0;
}

fn getUint64(_: *anyopaque, _: *const mf.Guid, out: *u64) callconv(mf.cc) mf.HRESULT {
    out.* = mf.packSize(320, 240);
    return 0;
}

fn activate(_: *anyopaque, _: *const mf.Guid, out: *?*anyopaque) callconv(mf.cc) mf.HRESULT {
    out.* = make();
    return 0;
}

fn shutdown(_: *anyopaque) callconv(mf.cc) mf.HRESULT {
    return 0;
}

fn setCurrent(_: *anyopaque, _: u32, _: ?*u32, _: *anyopaque) callconv(mf.cc) mf.HRESULT {
    if (refuse == .all) return -1;
    if (refuse == .yuy2 and std.meta.eql(last_subtype, mf.format_yuy2)) return -1;
    return 0;
}

fn getCurrent(_: *anyopaque, _: u32, out: *?*anyopaque) callconv(mf.cc) mf.HRESULT {
    out.* = make();
    return 0;
}

fn vtable() [42]?*const anyopaque {
    var entries: [42]?*const anyopaque = @splat(null);
    entries[mf.slot.release] = @ptrCast(&release);
    entries[mf.slot.set_guid] = @ptrCast(&setGuid);
    entries[mf.slot.set_uint32] = @ptrCast(&setUint32);
    entries[mf.slot.set_uint64] = @ptrCast(&setUint64);
    entries[mf.slot.get_uint64] = @ptrCast(&getUint64);
    entries[mf.slot.activate_object] = @ptrCast(&activate);
    entries[mf.slot.shutdown_object] = @ptrCast(&shutdown);
    entries[mf.slot.reader_set_current_media_type] = @ptrCast(&setCurrent);
    entries[mf.slot.reader_get_current_media_type] = @ptrCast(&getCurrent);
    return entries;
}

fn startup() mf.HRESULT {
    started += 1;
    return 0;
}

fn stop() void {
    started -= 1;
}

fn create(out: *?*anyopaque) mf.HRESULT {
    out.* = make();
    return 0;
}

fn enumerate(_: *anyopaque, out: *?[*]?*anyopaque, count: *u32) mf.HRESULT {
    for (devices[0..device_count]) |*slot| slot.* = make();
    out.* = &devices;
    count.* = device_count;
    return 0;
}

fn reader(_: *anyopaque, _: ?*anyopaque, out: *?*anyopaque) mf.HRESULT {
    out.* = make();
    return 0;
}

fn free(_: ?*anyopaque) void {}

const calls = mf_open.Calls{ .startup = startup, .shutdown = stop, .create_attributes = create, .create_media_type = create, .enum_devices = enumerate, .create_reader = reader, .free = free };

test "the second camera opens as YUY2 at the size the reader settled on" {
    reset();
    var opened = try mf_open.open(calls, 1, 640, 480);
    try std.testing.expectEqual(mf_open.Subtype.yuy2, opened.subtype);
    try std.testing.expectEqual(@as(u32, 320), opened.width);
    try std.testing.expectEqual(@as(u32, 240), opened.height);
    try std.testing.expectEqual(@as(i32, 2), live);
    opened.close();
    try std.testing.expectEqual(@as(i32, 0), live);
    try std.testing.expectEqual(@as(i32, 0), started);
}

test "a camera that refuses YUY2 is read as RGB32" {
    reset();
    refuse = .yuy2;
    var opened = try mf_open.open(calls, 0, 640, 480);
    try std.testing.expectEqual(mf_open.Subtype.rgb32, opened.subtype);
    opened.close();
    try std.testing.expectEqual(@as(i32, 0), live);
}

test "a missing camera or no usable format leaves nothing open" {
    reset();
    try std.testing.expectError(error.NoDevice, mf_open.open(calls, 2, 640, 480));
    try std.testing.expectEqual(@as(i32, 0), live);
    try std.testing.expectEqual(@as(i32, 0), started);
    reset();
    refuse = .all;
    try std.testing.expectError(error.NoFormat, mf_open.open(calls, 0, 640, 480));
    try std.testing.expectEqual(@as(i32, 0), live);
    try std.testing.expectEqual(@as(i32, 0), started);
}

test "only Windows has the real calls" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    try std.testing.expect(mf_open.system() == null);
}
