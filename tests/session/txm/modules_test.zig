//! Tests for src/session/txm/modules.zig: the pinned TXM_MODULE_INSTANCE
//! offsets, the walk of the circular loaded list, and where it stops.
const std = @import("std");
const ra8 = @import("ra8");
const txm = ra8.session.txm.modules;

const base: u32 = 0x2000_0000;
const head_at: u32 = base;
const first: u32 = base + 0x100;
const second: u32 = first + 1180;
const names_at: u32 = second + 1180;

/// A slice of target memory starting at `base`; anything outside it fails.
const Window = struct {
    bytes: []const u8,

    pub fn read(self: Window, address: u32, into: []u8) bool {
        if (address < base) return false;
        const at = address - base;
        if (at + into.len > self.bytes.len) return false;
        @memcpy(into, self.bytes[at .. at + into.len]);
        return true;
    }
};

const size = names_at - base + 64;

fn put(bytes: *[size]u8, at: u32, value: u32) void {
    std.mem.writeInt(u32, bytes[at - base ..][0..4], value, .little);
}

fn instance(bytes: *[size]u8, at: u32, name_at: u32, state: u32, next: u32) void {
    put(bytes, at + txm.offset.id, txm.instance_id);
    put(bytes, at + txm.offset.name, name_at);
    put(bytes, at + txm.offset.state, state);
    put(bytes, at + txm.offset.code_start, at + 0x10_0000);
    put(bytes, at + txm.offset.code_size, 0x800);
    put(bytes, at + txm.offset.data_start, at + 0x20_0000);
    put(bytes, at + txm.offset.data_size, 0x400);
    put(bytes, at + txm.offset.loaded_next, next);
}

/// Two modules on a circular list: hello started, fault loaded.
fn twoModules() [size]u8 {
    var bytes = @as([size]u8, @splat(0));
    put(&bytes, head_at, first);
    instance(&bytes, first, names_at, 2, second);
    instance(&bytes, second, names_at + 16, 1, first);
    @memcpy(bytes[names_at - base ..][0..5], "hello");
    @memcpy(bytes[names_at + 16 - base ..][0..5], "fault");
    return bytes;
}

test "the offsets are the ones measured on the firmware's M85 manager" {
    try std.testing.expectEqual(@as(u32, 0x4D4F4455), txm.instance_id);
    try std.testing.expectEqual(@as(u32, 4), txm.offset.name);
    try std.testing.expectEqual(@as(u32, 8), txm.offset.state);
    try std.testing.expectEqual(@as(u32, 24), txm.offset.code_start);
    try std.testing.expectEqual(@as(u32, 32), txm.offset.code_size);
    try std.testing.expectEqual(@as(u32, 44), txm.offset.data_start);
    try std.testing.expectEqual(@as(u32, 56), txm.offset.data_size);
    try std.testing.expectEqual(@as(u32, 1172), txm.offset.loaded_next);
}

test "the walk follows the list once round and stops at the first entry" {
    const bytes = twoModules();
    var into: [8]txm.Module = undefined;
    const count = txm.loaded(Window{ .bytes = &bytes }, head_at, &into);
    try std.testing.expectEqual(@as(usize, 2), count);
    try std.testing.expectEqual(first, into[0].instance);
    try std.testing.expectEqual(txm.State.started, into[0].state);
    try std.testing.expectEqual(second, into[1].instance);
    try std.testing.expectEqual(txm.State.loaded, into[1].state);
    try std.testing.expectEqual(first + 0x10_0000, into[0].code_start);
    try std.testing.expectEqual(@as(u32, 0x400), into[1].data_size);
}

test "names come from the instance's name pointer" {
    const bytes = twoModules();
    const memory = Window{ .bytes = &bytes };
    var into: [2]txm.Module = undefined;
    _ = txm.loaded(memory, head_at, &into);
    var buffer: [txm.longest]u8 = undefined;
    try std.testing.expectEqualStrings("hello", txm.name(memory, into[0], &buffer).?);
    try std.testing.expectEqualStrings("fault", txm.name(memory, into[1], &buffer).?);
}

test "an empty list head reports nothing" {
    var bytes = twoModules();
    put(&bytes, head_at, 0);
    var into: [8]txm.Module = undefined;
    try std.testing.expectEqual(@as(usize, 0), txm.loaded(Window{ .bytes = &bytes }, head_at, &into));
}

test "an entry without TXM_MODULE_ID ends the walk" {
    var bytes = twoModules();
    put(&bytes, second + txm.offset.id, 0);
    var into: [8]txm.Module = undefined;
    try std.testing.expectEqual(@as(usize, 1), txm.loaded(Window{ .bytes = &bytes }, head_at, &into));
}

test "a list that never returns to its head stops when the output is full" {
    var bytes = twoModules();
    put(&bytes, second + txm.offset.loaded_next, second);
    var into: [3]txm.Module = undefined;
    try std.testing.expectEqual(@as(usize, 3), txm.loaded(Window{ .bytes = &bytes }, head_at, &into));
}

test "states off the list read as unknown" {
    try std.testing.expectEqualStrings("unloaded", txm.State.unloaded.text());
    try std.testing.expectEqualStrings("unknown", @as(txm.State, @fromBackingInt(@intCast(9))).text());
}
