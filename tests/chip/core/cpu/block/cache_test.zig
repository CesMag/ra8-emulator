//! Covers src/chip/core/cpu/block/cache.zig.
const std = @import("std");
const ra8 = @import("ra8");
const bus = ra8.chip.core.cpu.bus;
const decode = ra8.chip.core.cpu.decode;
const BlockCache = decode.block_cache.BlockCache;

const Ram = struct {
    bytes: [64]u8 = @splat(0),

    fn view(self: *Ram) bus.Bus {
        return .{ .ctx = self, .vtable = &.{ .read = read, .write = write } };
    }

    fn put(self: *Ram, at: u32, half: u16) void {
        std.mem.writeInt(u16, self.bytes[at..][0..2], half, .little);
    }

    fn read(ctx: *anyopaque, address: u32, into: []u8) bus.Error!void {
        const self: *Ram = @ptrCast(@alignCast(ctx));
        if (address + into.len > self.bytes.len) return bus.Error.Unmapped;
        @memcpy(into, self.bytes[address..][0..into.len]);
    }

    fn write(ctx: *anyopaque, address: u32, from: []const u8) bus.Error!void {
        _ = .{ ctx, address, from };
        return bus.Error.Unmapped;
    }
};

const m85 = decode.profile.Profile.m85;

fn freshCache() !*BlockCache {
    const cache = try std.testing.allocator.create(BlockCache);
    cache.init();
    return cache;
}

fn straightRun(ram: *Ram) void {
    ram.put(0, 0x2001); // movs r0,#1
    ram.put(2, 0x2102); // movs r1,#2
    ram.put(4, 0xE7FA); // b 0
}

test "a walk through a block forms it once and reuses it" {
    var ram: Ram = .{};
    straightRun(&ram);
    const cache = try freshCache();
    defer std.testing.allocator.destroy(cache);
    for (0..2) |_| {
        for ([_]u32{ 0, 2, 4 }) |at| {
            const kept = cache.next(ram.view(), m85, at).?;
            try std.testing.expectEqual(at, kept.instr.address);
        }
    }
    try std.testing.expectEqual(@as(u64, 1), cache.formed);
    try std.testing.expectEqual(@as(u64, 1), cache.reused);
    try std.testing.expectEqual(@as(u64, 0), cache.stale);
}

test "rewritten code is never handed out stale" {
    var ram: Ram = .{};
    straightRun(&ram);
    const cache = try freshCache();
    defer std.testing.allocator.destroy(cache);
    _ = cache.next(ram.view(), m85, 0).?;
    ram.put(2, 0x2207); // movs r2,#7
    try std.testing.expect(cache.next(ram.view(), m85, 2) == null);
    try std.testing.expectEqual(@as(u64, 1), cache.stale);
    const again = cache.next(ram.view(), m85, 0).?;
    try std.testing.expectEqual(@as(u16, 0x2001), again.instr.hw1);
    try std.testing.expectEqual(@as(u16, 0x2207), cache.next(ram.view(), m85, 2).?.instr.hw1);
    try std.testing.expectEqual(@as(u64, 2), cache.formed);
}

test "a jump into the middle of a block starts a block there" {
    var ram: Ram = .{};
    straightRun(&ram);
    const cache = try freshCache();
    defer std.testing.allocator.destroy(cache);
    _ = cache.next(ram.view(), m85, 0).?;
    const mid = cache.next(ram.view(), m85, 4).?;
    try std.testing.expectEqual(@as(u16, 0xE7FA), mid.instr.hw1);
    try std.testing.expectEqual(@as(u64, 2), cache.formed);
}

test "an address that cannot be fetched is left to the step" {
    var ram: Ram = .{};
    const cache = try freshCache();
    defer std.testing.allocator.destroy(cache);
    try std.testing.expect(cache.next(ram.view(), m85, 64) == null);
}

test "an exception mid-block leaves it and resumes at the interrupted instruction" {
    var ram: Ram = .{};
    straightRun(&ram);
    ram.put(32, 0x4770); // the handler: bx lr
    const cache = try freshCache();
    defer std.testing.allocator.destroy(cache);
    _ = cache.next(ram.view(), m85, 0).?;
    // Taken before the instruction at 2: the handler runs, then 2 resumes.
    try std.testing.expectEqual(@as(u16, 0x4770), cache.next(ram.view(), m85, 32).?.instr.hw1);
    const resumed = cache.next(ram.view(), m85, 2).?;
    try std.testing.expectEqual(@as(u32, 2), resumed.instr.address);
    try std.testing.expectEqual(@as(u16, 0x2102), resumed.instr.hw1);
    try std.testing.expectEqual(@as(u32, 4), cache.next(ram.view(), m85, 4).?.instr.address);
    try std.testing.expectEqual(@as(u64, 0), cache.stale);
}

const SramRam = struct {
    bytes: [64]u8 = @splat(0),
    const base = ra8.chip.core.memmap.sram_base;

    fn view(self: *SramRam) bus.Bus {
        return .{ .ctx = self, .vtable = &.{ .read = read, .write = write } };
    }

    fn read(ctx: *anyopaque, address: u32, into: []u8) bus.Error!void {
        const self: *SramRam = @ptrCast(@alignCast(ctx));
        if (address < base or address - base + into.len > self.bytes.len) return bus.Error.Unmapped;
        @memcpy(into, self.bytes[address - base ..][0..into.len]);
    }

    fn write(ctx: *anyopaque, address: u32, from: []const u8) bus.Error!void {
        const self: *SramRam = @ptrCast(@alignCast(ctx));
        if (address < base or address - base + from.len > self.bytes.len) return bus.Error.Unmapped;
        @memcpy(self.bytes[address - base ..][0..from.len], from);
    }
};

test "a store over a cached block through the bus drops it and the new code runs" {
    var ram: SramRam = .{};
    std.mem.writeInt(u16, ram.bytes[0..2], 0x2001, .little); // movs r0,#1
    std.mem.writeInt(u16, ram.bytes[2..4], 0x2102, .little); // movs r1,#2
    std.mem.writeInt(u16, ram.bytes[4..6], 0xE7FE, .little); // b .
    const cache = try freshCache();
    defer std.testing.allocator.destroy(cache);
    const view = ram.view();
    try decode.code_lines.watch(&cache.lines);
    defer decode.code_lines.unwatch(&cache.lines);
    _ = cache.next(view, m85, SramRam.base).?;
    var patch: [2]u8 = undefined;
    std.mem.writeInt(u16, &patch, 0x2207, .little); // movs r2,#7
    try view.write(SramRam.base + 2, &patch);
    const after = cache.next(view, m85, SramRam.base + 2).?;
    try std.testing.expectEqual(@as(u64, 1), cache.dropped);
    try std.testing.expectEqual(@as(u16, 0x2207), after.instr.hw1);
    try std.testing.expectEqual(@as(u64, 0), cache.stale);
}

test "a write that bypasses the bus drops the block once it is reported" {
    var ram: SramRam = .{};
    std.mem.writeInt(u16, ram.bytes[0..2], 0x2001, .little); // movs r0,#1
    std.mem.writeInt(u16, ram.bytes[2..4], 0xE7FE, .little); // b .
    const cache = try freshCache();
    defer std.testing.allocator.destroy(cache);
    try decode.code_lines.watch(&cache.lines);
    defer decode.code_lines.unwatch(&cache.lines);
    _ = cache.next(ram.view(), m85, SramRam.base).?;
    // A DMA-style copy straight into memory, reported the way Engine.write does.
    std.mem.writeInt(u16, ram.bytes[0..2], 0x2309, .little); // movs r3,#9
    decode.code_lines.notify(SramRam.base, 2);
    const after = cache.next(ram.view(), m85, SramRam.base).?;
    try std.testing.expectEqual(@as(u64, 1), cache.dropped);
    try std.testing.expectEqual(@as(u16, 0x2309), after.instr.hw1);
}

test "an unwatched cache hears nothing" {
    const cache = try freshCache();
    defer std.testing.allocator.destroy(cache);
    cache.lines.mark(SramRam.base, SramRam.base + 4);
    decode.code_lines.notify(SramRam.base, 2);
    try std.testing.expect(!cache.lines.dirty);
}

test "a block in tracked memory is trusted and one outside it is re-checked" {
    var ram: SramRam = .{};
    std.mem.writeInt(u16, ram.bytes[0..2], 0x2001, .little); // movs r0,#1
    std.mem.writeInt(u16, ram.bytes[2..4], 0xE7FE, .little); // b .
    const cache = try freshCache();
    defer std.testing.allocator.destroy(cache);
    _ = cache.next(ram.view(), m85, SramRam.base).?;
    try std.testing.expect(cache.current.?.tracked);
    // Rewritten with no report: the trusted block hands out what it formed.
    std.mem.writeInt(u16, ram.bytes[0..2], 0x2309, .little);
    cache.current = null;
    const kept = cache.next(ram.view(), m85, SramRam.base).?;
    try std.testing.expectEqual(@as(u16, 0x2001), kept.instr.hw1);
    try std.testing.expectEqual(@as(u64, 0), cache.stale);

    var low: Ram = .{};
    straightRun(&low);
    _ = cache.next(low.view(), m85, 0).?;
    try std.testing.expect(!cache.current.?.tracked);
}
