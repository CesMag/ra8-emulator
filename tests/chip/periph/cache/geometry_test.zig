//! CTR and CCSIDR: the arithmetic the driver does on them.
const std = @import("std");
const ra8 = @import("ra8");

const geometry = ra8.chip.periph.cache_geometry;

test "a zero CTR reports a four-byte line, which is the bug this exists for" {
    try std.testing.expectEqual(@as(u32, 4), geometry.lineBytes(0));
}

test "the primed CTR reports this core's 32-byte line" {
    try std.testing.expectEqual(@as(u32, 32), geometry.lineBytes(geometry.reportedCtr()));
}

test "DminLine is the log2 of the line in words" {
    try std.testing.expectEqual(@as(u32, 3), geometry.dminFor(32));
    try std.testing.expectEqual(@as(u32, 0), geometry.dminFor(4));
    try std.testing.expectEqual(@as(u32, 5), geometry.dminFor(128));
}

test "the reported CTR carries the same line size in both fields" {
    const value = geometry.reportedCtr();
    const dmin = (value >> geometry.ctr.dmin_shift) & geometry.ctr.dmin_mask;
    const imin = (value >> geometry.ctr.imin_shift) & geometry.ctr.imin_mask;
    try std.testing.expectEqual(dmin, imin);
}

test "a DminLine never reaches outside its own four bits" {
    try std.testing.expect(geometry.dminFor(4 << 20) <= geometry.ctr.dmin_mask);
    try std.testing.expect(geometry.dminFor(0x8000_0000) <= geometry.ctr.dmin_mask);
}

test "both spellings of an absent geometry are the driver's own guard" {
    try std.testing.expect(geometry.unavailable(0));
    try std.testing.expect(geometry.unavailable(0xFFFF_FFFF));
    try std.testing.expect(!geometry.unavailable(0x0001_0032));
}

test "sets and ways are held minus one" {
    const value = (@as(u32, 255) << geometry.ccsidr.sets_shift) |
        (@as(u32, 3) << geometry.ccsidr.assoc_shift);
    try std.testing.expectEqual(@as(u32, 256), geometry.sets(value));
    try std.testing.expectEqual(@as(u32, 4), geometry.ways(value));
}

test "a walk over an absent geometry writes nothing" {
    try std.testing.expectEqual(@as(u64, 0), geometry.setWayStores(0));
    try std.testing.expectEqual(@as(u64, 0), geometry.setWayStores(0xFFFF_FFFF));
}

test "a walk over a real geometry writes one store per set per way" {
    const value = (@as(u32, 127) << geometry.ccsidr.sets_shift) |
        (@as(u32, 3) << geometry.ccsidr.assoc_shift);
    try std.testing.expectEqual(@as(u64, 512), geometry.setWayStores(value));
}

test "a range clean does eight times the stores at a four-byte line" {
    const wrong = geometry.rangeStores(0, 0x2200_0000, 4096);
    const right = geometry.rangeStores(geometry.reportedCtr(), 0x2200_0000, 4096);
    try std.testing.expectEqual(@as(u32, 1024), wrong);
    try std.testing.expectEqual(@as(u32, 128), right);
}

test "a range is rounded out to the lines that hold its ends" {
    const ctr = geometry.reportedCtr();
    try std.testing.expectEqual(@as(u32, 2), geometry.rangeStores(ctr, 0x2200_0010, 32));
    try std.testing.expectEqual(@as(u32, 1), geometry.rangeStores(ctr, 0x2200_0000, 32));
    try std.testing.expectEqual(@as(u32, 1), geometry.rangeStores(ctr, 0x2200_0000, 1));
}

test "an empty range is maintained with no stores at all" {
    try std.testing.expectEqual(@as(u32, 0), geometry.rangeStores(geometry.reportedCtr(), 0x2200_0000, 0));
}

test "the two CCR enables are distinct bits" {
    try std.testing.expectEqual(@as(u32, 1 << 16), geometry.ccr.dcache);
    try std.testing.expectEqual(@as(u32, 1 << 17), geometry.ccr.icache);
    try std.testing.expectEqual(geometry.ccr.dcache | geometry.ccr.icache, geometry.ccr.both);
}
