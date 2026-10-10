//! Tests for src/session/debug_read.zig.
const std = @import("std");
const ra8 = @import("ra8");
const bus = ra8.chip.core.cpu.bus;
const debug_read = ra8.session.step_hook.debug_read;

/// A bus that logs each access and peeks from `peek_from` up.
const Probe = struct {
    reads: [16][2]u32 = undefined,
    read_count: usize = 0,
    peeks: [16][2]u32 = undefined,
    peek_count: usize = 0,
    peek_from: u32 = std.math.maxInt(u32),

    fn view(self: *Probe) bus.Bus {
        return .{ .ctx = self, .vtable = &.{ .read = read, .write = write, .peek = peek } };
    }

    fn read(ctx: *anyopaque, address: u32, into: []u8) bus.Error!void {
        const self: *Probe = @ptrCast(@alignCast(ctx));
        self.reads[self.read_count] = .{ address, @intCast(into.len) };
        self.read_count += 1;
        @memset(into, 0x11);
    }

    fn write(_: *anyopaque, _: u32, _: []const u8) bus.Error!void {}

    fn peek(ctx: *anyopaque, address: u32, into: []u8) bool {
        const self: *Probe = @ptrCast(@alignCast(ctx));
        if (address < self.peek_from) return false;
        self.peeks[self.peek_count] = .{ address, @intCast(into.len) };
        self.peek_count += 1;
        @memset(into, 0xAA);
        return true;
    }
};

test "a range clear of the peripheral windows is one access" {
    var probe: Probe = .{};
    var into: [16]u8 = undefined;
    try debug_read.read(probe.view(), 0x2200_0001, &into);
    try std.testing.expectEqual(@as(usize, 1), probe.read_count);
    try std.testing.expectEqual([2]u32{ 0x2200_0001, 16 }, probe.reads[0]);
}

test "a window range goes through as aligned word, half and byte pieces" {
    var probe: Probe = .{};
    var into: [9]u8 = undefined;
    try debug_read.read(probe.view(), 0x4020_2001, &into);
    const want = [_][2]u32{ .{ 0x4020_2001, 1 }, .{ 0x4020_2002, 2 }, .{ 0x4020_2004, 4 }, .{ 0x4020_2008, 2 } };
    try std.testing.expectEqual(want.len, probe.read_count);
    for (want, probe.reads[0..want.len]) |w, got| try std.testing.expectEqual(w, got);
}

test "a piece a block can peek is peeked, never read" {
    var probe: Probe = .{ .peek_from = 0x5020_2004 };
    var into: [8]u8 = undefined;
    try debug_read.read(probe.view(), 0x5020_2000, &into);
    try std.testing.expectEqual(@as(usize, 1), probe.read_count);
    try std.testing.expectEqual([2]u32{ 0x5020_2000, 4 }, probe.reads[0]);
    try std.testing.expectEqual(@as(usize, 1), probe.peek_count);
    try std.testing.expectEqual([2]u32{ 0x5020_2004, 4 }, probe.peeks[0]);
    try std.testing.expectEqualSlices(u8, &.{ 0x11, 0x11, 0x11, 0x11, 0xAA, 0xAA, 0xAA, 0xAA }, &into);
}

test "a range only touching a window's edge still splits" {
    try std.testing.expect(debug_read.touchesWindow(0x3FFF_FFFC, 8));
    try std.testing.expect(!debug_read.touchesWindow(0x3FFF_FFF8, 8));
    try std.testing.expect(debug_read.touchesWindow(0x5FFF_FFFF, 4));
    try std.testing.expect(!debug_read.touchesWindow(0x6000_0000, 4));
    try std.testing.expect(!debug_read.touchesWindow(0x4000_0000, 0));
}
