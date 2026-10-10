//! Tests for src/session/rtos_names.zig: where the name pointer is read from,
//! and what falls back to the bare pointer.
const std = @import("std");
const ra8 = @import("ra8");
const names = ra8.session.step_hook.rtos_hook.names;

/// A slice of target memory starting at `base`; anything outside it fails.
const Window = struct {
    base: u32,
    bytes: []const u8,

    pub fn read(self: Window, address: u32, into: []u8) bool {
        if (address < self.base) return false;
        const at = address - self.base;
        if (at + into.len > self.bytes.len) return false;
        @memcpy(into, self.bytes[at .. at + into.len]);
        return true;
    }
};

fn block(name_at: u32) [64]u8 {
    var bytes = @as([64]u8, @splat(0));
    std.mem.writeInt(u32, bytes[names.name_offset..][0..4], name_at, .little);
    return bytes;
}

test "the name is the string the pointer at byte 40 names" {
    var bytes = block(0x1000 + 48);
    @memcpy(bytes[48..56], "thread a");
    var buffer: [names.longest]u8 = undefined;
    const got = names.name(Window{ .base = 0x1000, .bytes = &bytes }, 0x1000, &buffer);
    try std.testing.expectEqualStrings("thread a", got.?);
}

test "a zero pointer, an unreadable block and an empty name give no name" {
    var buffer: [names.longest]u8 = undefined;
    const zero = block(0);
    try std.testing.expect(names.name(Window{ .base = 0x1000, .bytes = &zero }, 0x1000, &buffer) == null);
    try std.testing.expect(names.name(Window{ .base = 0x1000, .bytes = &zero }, 0x2000, &buffer) == null);
    const empty = block(0x1000 + 48);
    try std.testing.expect(names.name(Window{ .base = 0x1000, .bytes = &empty }, 0x1000, &buffer) == null);
    try std.testing.expect(names.name(names.none, 0x1000, &buffer) == null);
}

test "bytes that are not text give no name, a long name is cut short" {
    var buffer: [names.longest]u8 = undefined;
    var junk = block(0x1000 + 48);
    junk[48] = 0xFF;
    try std.testing.expect(names.name(Window{ .base = 0x1000, .bytes = &junk }, 0x1000, &buffer) == null);
    var long = @as([96]u8, @splat('x'));
    @memset(long[0..48], 0);
    std.mem.writeInt(u32, long[names.name_offset..][0..4], 0x1000 + 48, .little);
    const got = names.name(Window{ .base = 0x1000, .bytes = &long }, 0x1000, &buffer);
    try std.testing.expectEqual(@as(usize, names.longest), got.?.len);
}
