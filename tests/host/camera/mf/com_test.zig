//! Covers src/host/camera/mf_com.zig: each wrapper calls its own
//! vtable slot with the object first, checked against a fake COM object.
const std = @import("std");
const ra8 = @import("ra8");
const mf = ra8.host.camera.mf;
const com = ra8.host.camera.mf_com;

const Fake = extern struct {
    vtable: [*]const ?*const anyopaque,
    hit: usize = 0,
    value: u64 = 0,
};

fn note(self: *anyopaque, slot: usize) *Fake {
    const fake: *Fake = @ptrCast(@alignCast(self));
    fake.hit = slot;
    return fake;
}

fn release(self: *anyopaque) callconv(mf.cc) u32 {
    _ = note(self, mf.slot.release);
    return 0;
}

fn setUint64(self: *anyopaque, key: *const mf.Guid, value: u64) callconv(mf.cc) mf.HRESULT {
    _ = key;
    note(self, mf.slot.set_uint64).value = value;
    return 0;
}

fn getUint64(self: *anyopaque, key: *const mf.Guid, value: *u64) callconv(mf.cc) mf.HRESULT {
    _ = key;
    _ = note(self, mf.slot.get_uint64);
    value.* = mf.packSize(320, 240);
    return 0;
}

fn lock(self: *anyopaque, bytes: *?[*]u8, max: ?*u32, length: *u32) callconv(mf.cc) mf.HRESULT {
    _ = note(self, mf.slot.buffer_lock);
    if (max != null) return -1;
    bytes.* = @ptrCast(@constCast("YUYV"));
    length.* = 4;
    return 0;
}

fn table() [42]?*const anyopaque {
    var entries: [42]?*const anyopaque = @splat(null);
    entries[mf.slot.release] = @ptrCast(&release);
    entries[mf.slot.set_uint64] = @ptrCast(&setUint64);
    entries[mf.slot.get_uint64] = @ptrCast(&getUint64);
    entries[mf.slot.buffer_lock] = @ptrCast(&lock);
    return entries;
}

test "wrappers land on their slots with the object first" {
    const entries = table();
    var fake = Fake{ .vtable = &entries };
    try std.testing.expectEqual(@as(mf.HRESULT, 0), com.setUint64(&fake, &mf.mt_frame_size, mf.packSize(640, 480)));
    try std.testing.expectEqual(@as(usize, mf.slot.set_uint64), fake.hit);
    try std.testing.expectEqual(mf.packSize(640, 480), fake.value);
    var got: u64 = 0;
    _ = com.getUint64(&fake, &mf.mt_frame_size, &got);
    try std.testing.expectEqual(@as(u32, 320), mf.unpackSize(got).width);
    com.release(&fake);
    try std.testing.expectEqual(@as(usize, mf.slot.release), fake.hit);
}

test "lock hands back the buffer bytes and skips the max length" {
    const entries = table();
    var fake = Fake{ .vtable = &entries };
    var bytes: ?[*]u8 = null;
    var length: u32 = 0;
    try std.testing.expectEqual(@as(mf.HRESULT, 0), com.lock(&fake, &bytes, &length));
    try std.testing.expectEqualStrings("YUYV", bytes.?[0..length]);
}
