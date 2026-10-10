//! The cache window: what it primes, what it counts, and what it refuses.
const std = @import("std");
const ra8 = @import("ra8");

const cache = ra8.chip.periph.cache;
const geometry = ra8.chip.periph.cache_geometry;
const memmap = ra8.chip.core.memmap;

/// A stand-in for the machine: the handful of PPB words this block touches,
/// answering reads and taking writes the way the plain-RAM mapping does.
const Ppb = struct {
    words: std.AutoHashMap(u32, u32),

    fn init(allocator: std.mem.Allocator) Ppb {
        return .{ .words = std.AutoHashMap(u32, u32).init(allocator) };
    }

    fn deinit(self: *Ppb) void {
        self.words.deinit();
    }

    pub fn readWord(self: *Ppb, at: u32) !u32 {
        return self.words.get(at) orelse 0;
    }

    pub fn writeWord(self: *Ppb, at: u32, value: u32) !void {
        try self.words.put(at, value);
    }
};

fn primed(ppb: *Ppb) !cache.Cache {
    var unit = cache.Cache.init();
    try unit.prime(ppb);
    return unit;
}

test "a fresh window is quiet and reports this core's line" {
    const unit = cache.Cache.init();
    try std.testing.expect(unit.quiet());
    try std.testing.expectEqual(@as(u32, 32), unit.lineBytes());
}

test "priming puts the geometry where the firmware reads it" {
    var ppb = Ppb.init(std.testing.allocator);
    defer ppb.deinit();
    var unit = try primed(&ppb);
    try std.testing.expectEqual(@as(u32, 32), geometry.lineBytes(try ppb.readWord(memmap.cache.ctr)));
    try std.testing.expect(geometry.unavailable(try ppb.readWord(memmap.cache.ccsidr)));
    _ = &unit;
}

test "priming leaves every maintenance port on the idle sentinel" {
    var ppb = Ppb.init(std.testing.allocator);
    defer ppb.deinit();
    var unit = try primed(&ppb);
    _ = &unit;
    for (0..cache.op_count) |index| {
        const which: cache.Op = @fromBackingInt(@intCast(index));
        try std.testing.expectEqual(cache.idle, try ppb.readWord(which.address()));
    }
}

test "an untouched window counts nothing at the boundary" {
    var ppb = Ppb.init(std.testing.allocator);
    defer ppb.deinit();
    var unit = try primed(&ppb);
    try unit.poll(&ppb);
    try std.testing.expectEqual(@as(u32, 0), unit.total());
    try std.testing.expect(unit.quiet());
}

test "an ICIALLU written with zero is still seen, which the sentinel is for" {
    var ppb = Ppb.init(std.testing.allocator);
    defer ppb.deinit();
    var unit = try primed(&ppb);
    try ppb.writeWord(memmap.cache.iciallu, 0);
    try unit.poll(&ppb);
    try std.testing.expectEqual(@as(u32, 1), unit.count(.icache_all));
    try std.testing.expectEqual(cache.idle, try ppb.readWord(memmap.cache.iciallu));
}

test "a clean by address is counted against its own register" {
    var ppb = Ppb.init(std.testing.allocator);
    defer ppb.deinit();
    var unit = try primed(&ppb);
    try ppb.writeWord(memmap.cache.dccmvac, 0x2200_0000);
    try unit.poll(&ppb);
    try std.testing.expectEqual(@as(u32, 1), unit.count(.clean));
    try std.testing.expectEqual(@as(u32, 0), unit.count(.invalidate));
    try std.testing.expectEqual(@as(u32, 1), unit.total());
}

test "many stores inside one chunk are one boundary, and the report says so" {
    var ppb = Ppb.init(std.testing.allocator);
    defer ppb.deinit();
    var unit = try primed(&ppb);
    for (0..128) |line| {
        try ppb.writeWord(memmap.cache.dccmvac, 0x2200_0000 + @as(u32, @intCast(line)) * 32);
    }
    try unit.poll(&ppb);
    try std.testing.expectEqual(@as(u32, 1), unit.count(.clean));
}

test "a second chunk of maintenance is a second boundary" {
    var ppb = Ppb.init(std.testing.allocator);
    defer ppb.deinit();
    var unit = try primed(&ppb);
    try ppb.writeWord(memmap.cache.dcimvac, 0x2200_0000);
    try unit.poll(&ppb);
    try ppb.writeWord(memmap.cache.dcimvac, 0x2200_0020);
    try unit.poll(&ppb);
    try std.testing.expectEqual(@as(u32, 2), unit.count(.invalidate));
}

test "both set/way spellings land under one question" {
    var ppb = Ppb.init(std.testing.allocator);
    defer ppb.deinit();
    var unit = try primed(&ppb);
    try ppb.writeWord(memmap.cache.dcisw, 0);
    try unit.poll(&ppb);
    try ppb.writeWord(memmap.cache.dccisw, 0);
    try unit.poll(&ppb);
    try std.testing.expectEqual(@as(u32, 2), unit.setWayAsked());
    try std.testing.expect(unit.walkDeclined());
}

test "CTR is read-only, so a store to it is turned away and put back" {
    var ppb = Ppb.init(std.testing.allocator);
    defer ppb.deinit();
    var unit = try primed(&ppb);
    try ppb.writeWord(memmap.cache.ctr, 0xDEAD_BEEF);
    try unit.poll(&ppb);
    try std.testing.expectEqual(@as(u32, 1), unit.refused);
    try std.testing.expectEqual(@as(u32, 32), geometry.lineBytes(try ppb.readWord(memmap.cache.ctr)));
}

test "CCSIDR is read-only too, and a firmware geometry does not stick" {
    var ppb = Ppb.init(std.testing.allocator);
    defer ppb.deinit();
    var unit = try primed(&ppb);
    try ppb.writeWord(memmap.cache.ccsidr, 0x0001_0032);
    try unit.poll(&ppb);
    try std.testing.expectEqual(@as(u32, 1), unit.refused);
    try std.testing.expect(geometry.unavailable(try ppb.readWord(memmap.cache.ccsidr)));
}

test "CSSELR is retained, because the walk selects with it" {
    var ppb = Ppb.init(std.testing.allocator);
    defer ppb.deinit();
    var unit = try primed(&ppb);
    try ppb.writeWord(memmap.cache.csselr, 0);
    try unit.poll(&ppb);
    try std.testing.expectEqual(@as(u32, 0), unit.selected);
    try std.testing.expectEqual(@as(u32, 0), unit.refused);
}

test "turning a cache on is noticed once, not on every boundary" {
    var ppb = Ppb.init(std.testing.allocator);
    defer ppb.deinit();
    var unit = try primed(&ppb);
    try ppb.writeWord(memmap.scb.ccr, geometry.ccr.icache);
    try unit.poll(&ppb);
    try unit.poll(&ppb);
    try std.testing.expect(unit.icacheOn());
    try std.testing.expect(!unit.dcacheOn());
    try std.testing.expectEqual(@as(u32, 1), unit.changes);
}

test "both caches on reads as both, and the run is no longer quiet" {
    var ppb = Ppb.init(std.testing.allocator);
    defer ppb.deinit();
    var unit = try primed(&ppb);
    try ppb.writeWord(memmap.scb.ccr, geometry.ccr.both);
    try unit.poll(&ppb);
    try std.testing.expect(unit.icacheOn());
    try std.testing.expect(unit.dcacheOn());
    try std.testing.expect(!unit.quiet());
}

test "every operation names itself and its own register" {
    var seen = std.AutoHashMap(u32, void).init(std.testing.allocator);
    defer seen.deinit();
    for (0..cache.op_count) |index| {
        const which: cache.Op = @fromBackingInt(@intCast(index));
        try std.testing.expect(which.name().len != 0);
        try std.testing.expect(!seen.contains(which.address()));
        try seen.put(which.address(), {});
    }
}
