//! Covers src/chip/core/cpu/decode/cache.zig.
const std = @import("std");
const ra8 = @import("ra8");
const decode = ra8.chip.core.cpu.decode;
const DecodeCache = decode.cache.DecodeCache;
const Instr = ra8.chip.core.cpu.instr.Instr;

const nop: Instr = .{ .address = 0x0200_0100, .hw1 = 0xBF00, .size = 2 };
const movs: Instr = .{ .address = 0x0200_0100, .hw1 = 0x2001, .size = 2 };

test "the second decode of an address comes from the table" {
    var cache: DecodeCache = .{};
    const first = cache.find(nop).?;
    const again = cache.find(nop).?;
    try std.testing.expectEqual(first.exec, again.exec);
    try std.testing.expectEqualStrings(decode.decode(nop).?.group, again.group);
    try std.testing.expectEqual(@as(u64, 1), cache.hits);
    try std.testing.expectEqual(@as(u64, 1), cache.misses);
}

test "code rewritten at a cached address decodes afresh" {
    var cache: DecodeCache = .{};
    _ = cache.find(nop);
    const rewritten = cache.find(movs).?;
    try std.testing.expectEqualStrings(decode.decode(movs).?.group, rewritten.group);
    try std.testing.expectEqual(decode.decode(movs).?.exec, rewritten.exec);
    try std.testing.expectEqual(@as(u64, 0), cache.hits);
}

test "a wide encoding is matched on both halfwords" {
    var cache: DecodeCache = .{};
    const bl: Instr = .{ .address = 0x0200_0200, .hw1 = 0xF000, .hw2 = 0xF800, .size = 4 };
    var other = bl;
    other.hw2 = 0xF801;
    _ = cache.find(bl);
    _ = cache.find(other);
    try std.testing.expectEqual(@as(u64, 0), cache.hits);
    _ = cache.find(other);
    try std.testing.expectEqual(@as(u64, 1), cache.hits);
}

test "two addresses sharing a slot each decode correctly" {
    var cache: DecodeCache = .{};
    var far = movs;
    far.address = nop.address + 2 * decode.cache.slots;
    try std.testing.expectEqual(decode.decode(nop).?.exec, cache.find(nop).?.exec);
    try std.testing.expectEqual(decode.decode(far).?.exec, cache.find(far).?.exec);
    try std.testing.expectEqual(decode.decode(nop).?.exec, cache.find(nop).?.exec);
    try std.testing.expectEqual(@as(u64, 0), cache.hits);
}

test "an encoding no group knows is not cached" {
    var cache: DecodeCache = .{};
    const unknown: Instr = .{ .address = 0x0200_0300, .hw1 = 0xFFFF, .hw2 = 0xFFFF, .size = 4 };
    try std.testing.expect(decode.decode(unknown) == null);
    try std.testing.expect(cache.find(unknown) == null);
    try std.testing.expect(cache.find(unknown) == null);
    try std.testing.expectEqual(@as(u64, 2), cache.misses);
}

// tests/all.zig is at its 400-line cap, so the block tests (RA8EMU-403)
// are pulled in from here, next to the cache they build on.
test {
    _ = @import("../block/block_test.zig");
    _ = @import("../block/end_test.zig");
    _ = @import("../block_cache_test.zig");
    _ = @import("../code_lines_test.zig");
}
