//! Covers src/chip/core/cpu/bus.zig.
const std = @import("std");
const ra8 = @import("ra8");
const bus = ra8.chip.core.cpu.bus;
const memmap = ra8.chip.core.memmap;

/// A Bus over one slice of bytes at a base address; anything outside it is
/// unmapped.
const Flat = struct {
    base: u32,
    bytes: []u8,
    reads: usize = 0,
    writes: usize = 0,

    fn view(self: *Flat) bus.Bus {
        return .{ .ctx = self, .vtable = &.{ .read = read, .write = write } };
    }

    fn span(self: *Flat, address: u32, len: usize) bus.Error![]u8 {
        if (address < self.base) return bus.Error.Unmapped;
        const at = address - self.base;
        if (at + len > self.bytes.len) return bus.Error.Unmapped;
        return self.bytes[at..][0..len];
    }

    fn read(ctx: *anyopaque, address: u32, into: []u8) bus.Error!void {
        const self: *Flat = @ptrCast(@alignCast(ctx));
        self.reads += 1;
        @memcpy(into, try self.span(address, into.len));
    }

    fn write(ctx: *anyopaque, address: u32, from: []const u8) bus.Error!void {
        const self: *Flat = @ptrCast(@alignCast(ctx));
        self.writes += 1;
        @memcpy(try self.span(address, from.len), from);
    }
};

test "halfwords and words read little-endian" {
    var bytes = [_]u8{ 0x00, 0xBF, 0xAF, 0xF3, 0x00, 0x80 };
    var flat: Flat = .{ .base = 0x0800_0000, .bytes = &bytes };
    const b = flat.view();
    try std.testing.expectEqual(@as(u16, 0xBF00), try b.readHalf(0x0800_0000));
    try std.testing.expectEqual(@as(u32, 0xF3AF_BF00), try b.readWord(0x0800_0000));
}

test "a write lands and an access outside the map fails" {
    var bytes = @as([4]u8, @splat(0));
    var flat: Flat = .{ .base = 0x2000_0000, .bytes = &bytes };
    const b = flat.view();
    try b.write(0x2000_0002, &.{ 0x34, 0x12 });
    try std.testing.expectEqual(@as(u16, 0x1234), try b.readHalf(0x2000_0002));
    try std.testing.expectError(bus.Error.Unmapped, b.readWord(0x2000_0002));
}

test "direct memory bypasses the vtable only while enabled" {
    var backing = [_]u8{ 0x11, 0x22, 0x33, 0x44 };
    var slow = [_]u8{ 0xAA, 0xBB, 0xCC, 0xDD };
    var flat: Flat = .{ .base = memmap.mram_base, .bytes = &slow };
    var direct: bus.DirectMemory = .{
        .flash = &backing,
        .enabled = true,
    };
    var view = flat.view();
    view.direct = &direct;

    try std.testing.expectEqual(@as(u32, 0x4433_2211), try view.readWord(flat.base));
    try std.testing.expectEqual(@as(usize, 0), flat.reads);
    try view.write(flat.base + 1, &.{ 0xFE, 0xCA });
    try std.testing.expectEqualSlices(u8, &.{ 0x11, 0xFE, 0xCA, 0x44 }, &backing);
    try std.testing.expectEqual(@as(usize, 0), flat.writes);

    try std.testing.expectError(bus.Error.Unmapped, view.readWord(memmap.sram_base));
    try std.testing.expectEqual(@as(usize, 1), flat.reads);

    direct.enabled = false;
    try std.testing.expectEqual(@as(u32, 0xDDCC_BBAA), try view.readWord(flat.base));
    try std.testing.expectEqual(@as(usize, 2), flat.reads);
}

test "an armed MPU check turns the direct path aside" {
    var backing = [_]u8{ 0x11, 0x22, 0x33, 0x44 };
    var slow = [_]u8{ 0xAA, 0xBB, 0xCC, 0xDD };
    var flat: Flat = .{ .base = memmap.mram_base, .bytes = &slow };
    var armed = true;
    var direct: bus.DirectMemory = .{ .flash = &backing, .enabled = true, .checking = &armed };
    var view = flat.view();
    view.direct = &direct;

    try view.write(flat.base, &.{0x5A});
    try std.testing.expectEqual(@as(usize, 1), flat.writes);
    try std.testing.expectEqual(@as(u8, 0x11), backing[0]);
    try std.testing.expectEqual(@as(u8, 0x5A), slow[0]);

    armed = false;
    try view.write(flat.base, &.{0x66});
    try std.testing.expectEqual(@as(usize, 1), flat.writes);
    try std.testing.expectEqual(@as(u8, 0x66), backing[0]);
}

test "a refused read or write records where it went" {
    var bytes = @as([4]u8, @splat(0));
    var flat: Flat = .{ .base = 0x2000_0000, .bytes = &bytes };
    var at: u32 = 0;
    var b = flat.view();
    b.miss = &at;
    try std.testing.expectError(bus.Error.Unmapped, b.readWord(0x3000_0000));
    try std.testing.expectEqual(@as(u32, 0x3000_0000), at);
    try std.testing.expectError(bus.Error.Unmapped, b.write(0x1000_0004, &.{0x55}));
    try std.testing.expectEqual(@as(u32, 0x1000_0004), at);
}

test "an access that lands leaves the recorded miss alone" {
    var bytes = @as([4]u8, @splat(0));
    var flat: Flat = .{ .base = 0x2000_0000, .bytes = &bytes };
    var at: u32 = 0xDEAD_BEEF;
    var b = flat.view();
    b.miss = &at;
    try b.write(0x2000_0000, &.{0x55});
    _ = try b.readWord(0x2000_0000);
    try std.testing.expectEqual(@as(u32, 0xDEAD_BEEF), at);
}
