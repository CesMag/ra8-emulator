//! Covers src/chip/core/cpu/block/block.zig.
const std = @import("std");
const ra8 = @import("ra8");
const bus = ra8.chip.core.cpu.bus;
const decode = ra8.chip.core.cpu.decode;
const block = decode.block;
const Instr = ra8.chip.core.cpu.instr.Instr;
const DecodeCache = decode.cache.DecodeCache;

const Rom = struct {
    bytes: []const u8,

    fn view(self: *Rom) bus.Bus {
        return .{ .ctx = self, .vtable = &.{ .read = read, .write = write } };
    }

    fn read(ctx: *anyopaque, address: u32, into: []u8) bus.Error!void {
        const self: *Rom = @ptrCast(@alignCast(ctx));
        if (address + into.len > self.bytes.len) return bus.Error.Unmapped;
        @memcpy(into, self.bytes[address..][0..into.len]);
    }

    fn write(ctx: *anyopaque, address: u32, from: []const u8) bus.Error!void {
        _ = .{ ctx, address, from };
        return bus.Error.Unmapped;
    }
};

fn formFrom(halves: []const u16) block.Block {
    var bytes: [256]u8 = undefined;
    for (halves, 0..) |h, i| std.mem.writeInt(u16, bytes[i * 2 ..][0..2], h, .little);
    var rom: Rom = .{ .bytes = bytes[0 .. halves.len * 2] };
    var cache: DecodeCache = .{};
    return block.Block.form(rom.view(), &cache, decode.profile.Profile.m85, 0);
}

test "a straight run ends after its branch" {
    // movs r0,#1; movs r1,#2; b .; movs r2,#3
    const b = formFrom(&.{ 0x2001, 0x2102, 0xE7FE, 0x2203 });
    try std.testing.expectEqual(@as(usize, 3), b.len);
    try std.testing.expectEqual(@as(u16, 0xE7FE), b.items()[2].instr.hw1);
    try std.testing.expectEqual(@as(u32, 6), b.end());
}

test "an IT ends the block it is in" {
    // movs r0,#1; it eq; moveq r1,r0
    const b = formFrom(&.{ 0x2001, 0xBF08, 0x4601 });
    try std.testing.expectEqual(@as(usize, 2), b.len);
}

test "a long run stops at the cap" {
    var nops: [block.cap + 8]u16 = undefined;
    @memset(&nops, 0xBF00);
    const b = formFrom(&nops);
    try std.testing.expectEqual(block.cap, b.len);
    try std.testing.expectEqual(@as(u32, block.cap * 2), b.end());
}

test "a pop into the pc ends the block" {
    // movs r0,#1; pop {r4, pc}; movs r1,#2
    const b = formFrom(&.{ 0x2001, 0xBD10, 0x2102 });
    try std.testing.expectEqual(@as(usize, 2), b.len);
}

test "wide instructions are held whole" {
    // push.w {r4, lr}; nop.w; bl (ends)
    const b = formFrom(&.{ 0xE92D, 0x4010, 0xF3AF, 0x8000, 0x2001 });
    try std.testing.expectEqual(@as(usize, 2), b.len);
    try std.testing.expectEqual(@as(u8, 4), b.items()[0].instr.size);
}

fn unknownWide() ?u16 {
    var hw1: u32 = 0xE800;
    while (hw1 <= 0xFFFF) : (hw1 += 1) {
        const probe: Instr = .{ .address = 2, .hw1 = @intCast(hw1), .hw2 = 0xFFFF, .size = 4 };
        if (decode.decodeFor(decode.profile.Profile.m85, probe) == null) return @intCast(hw1);
    }
    return null;
}

test "an encoding nothing decodes ends the block before it" {
    const hw1 = unknownWide() orelse return error.NoUnknownEncoding;
    const b = formFrom(&.{ 0x2001, hw1, 0xFFFF, 0x2102 });
    try std.testing.expectEqual(@as(usize, 1), b.len);
    try std.testing.expectEqual(@as(u32, 2), b.end());
}

test "running off mapped memory ends the block" {
    const b = formFrom(&.{ 0x2001, 0x2102 });
    try std.testing.expectEqual(@as(usize, 2), b.len);
}
