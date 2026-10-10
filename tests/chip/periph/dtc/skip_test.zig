//! DTCCR.RRS, the read-skip cache: what a repeated vector does and does not
//! re-read, and what drops a held descriptor.
const std = @import("std");
const ra8 = @import("ra8");
const skip = ra8.chip.periph.dtc.skip;
const xfer = ra8.chip.periph.dtc.xfer;

/// A plain normal-mode descriptor: byte units, both addresses incrementing.
fn info(sar: u32, dar: u32, units: u16) xfer.Info {
    return xfer.Info.decode(0x0808_0000, sar, dar, 0, units);
}

test "RRS is bit 4, and the two values the driver writes read as off and on" {
    try std.testing.expect(!skip.enabled(skip.field.rrs_off));
    try std.testing.expect(skip.enabled(skip.field.rrs_on));
    try std.testing.expectEqual(@as(u8, 0x08), skip.field.rrs_off);
    try std.testing.expectEqual(@as(u8, 0x18), skip.field.rrs_on);
}

test "the reserved bit alone does not switch the skip on" {
    try std.testing.expect(!skip.enabled(skip.field.reserved));
    try std.testing.expect(skip.enabled(skip.field.rrs));
}

test "a fresh cache holds nothing and stays out of the report" {
    var cache = skip.Cache{};
    try std.testing.expect(cache.quiet());
    try std.testing.expect(!cache.holds(9));
}

test "the first activation on a vector reads memory however RRS stands" {
    var cache = skip.Cache{};
    try std.testing.expect(cache.fetch(skip.field.rrs_on, 25) == null);
    try std.testing.expectEqual(@as(u32, 1), cache.reads);
    try std.testing.expectEqual(@as(u32, 0), cache.skips);
}

test "a repeated vector with RRS set skips the read and answers the held copy" {
    var cache = skip.Cache{};
    _ = cache.fetch(skip.field.rrs_on, 25);
    cache.keep(25, info(0x2200_0000, 0x2200_1000, 4));
    const held = cache.fetch(skip.field.rrs_on, 25);
    try std.testing.expect(held != null);
    try std.testing.expectEqual(@as(u32, 0x2200_0000), held.?.sar);
    try std.testing.expectEqual(@as(u32, 1), cache.skips);
    try std.testing.expectEqual(@as(u32, 1), cache.reads);
}

test "a repeated vector with RRS clear reads memory again" {
    var cache = skip.Cache{};
    cache.keep(25, info(0x2200_0000, 0x2200_1000, 4));
    try std.testing.expect(cache.fetch(skip.field.rrs_off, 25) == null);
    try std.testing.expectEqual(@as(u32, 1), cache.reads);
    try std.testing.expectEqual(@as(u32, 0), cache.skips);
}

test "a different vector reads memory even with RRS set" {
    var cache = skip.Cache{};
    cache.keep(25, info(0x2200_0000, 0x2200_1000, 4));
    try std.testing.expect(cache.fetch(skip.field.rrs_on, 26) == null);
    try std.testing.expectEqual(@as(u32, 1), cache.reads);
}

test "the held copy is the one kept last, not the one kept first" {
    var cache = skip.Cache{};
    cache.keep(25, info(0x2200_0000, 0x2200_1000, 4));
    cache.keep(25, info(0x2200_0001, 0x2200_1001, 3));
    const held = cache.fetch(skip.field.rrs_on, 25).?;
    try std.testing.expectEqual(@as(u32, 0x2200_0001), held.sar);
    try std.testing.expectEqual(@as(u16, 3), held.cra);
}

test "keeping a second vector displaces the first" {
    var cache = skip.Cache{};
    cache.keep(25, info(0x2200_0000, 0x2200_1000, 4));
    cache.keep(26, info(0x2300_0000, 0x2300_1000, 2));
    try std.testing.expect(!cache.holds(25));
    try std.testing.expect(cache.holds(26));
}

test "clearing RRS drops the held copy, so the next activation reads memory" {
    var cache = skip.Cache{};
    cache.keep(25, info(0x2200_0000, 0x2200_1000, 4));
    cache.latch(skip.field.rrs_on, skip.field.rrs_off);
    try std.testing.expectEqual(@as(u32, 1), cache.drops);
    try std.testing.expect(cache.fetch(skip.field.rrs_on, 25) == null);
}

test "the driver's off-then-on toggle leaves nothing held" {
    var cache = skip.Cache{};
    cache.keep(25, info(0x2200_0000, 0x2200_1000, 4));
    cache.latch(skip.field.rrs_on, skip.field.rrs_off);
    cache.latch(skip.field.rrs_off, skip.field.rrs_on);
    try std.testing.expect(!cache.holds(25));
    try std.testing.expectEqual(@as(u32, 1), cache.drops);
}

test "setting RRS on its own drops nothing" {
    var cache = skip.Cache{};
    cache.keep(25, info(0x2200_0000, 0x2200_1000, 4));
    cache.latch(skip.field.rrs_off, skip.field.rrs_on);
    try std.testing.expect(cache.holds(25));
    try std.testing.expectEqual(@as(u32, 0), cache.drops);
}

test "a write that leaves RRS where it was drops nothing" {
    var cache = skip.Cache{};
    cache.keep(25, info(0x2200_0000, 0x2200_1000, 4));
    cache.latch(skip.field.rrs_on, skip.field.rrs_on);
    cache.latch(skip.field.rrs_off, skip.field.rrs_off);
    try std.testing.expectEqual(@as(u32, 0), cache.drops);
}

test "dropping nothing is not counted" {
    var cache = skip.Cache{};
    cache.drop();
    cache.drop();
    try std.testing.expectEqual(@as(u32, 0), cache.drops);
    try std.testing.expect(cache.quiet());
}

test "a dropped copy is gone even with RRS still set" {
    var cache = skip.Cache{};
    cache.keep(25, info(0x2200_0000, 0x2200_1000, 4));
    cache.drop();
    try std.testing.expect(cache.fetch(skip.field.rrs_on, 25) == null);
    try std.testing.expectEqual(@as(u32, 1), cache.drops);
}

test "any activation at all takes the cache out of quiet" {
    var cache = skip.Cache{};
    _ = cache.fetch(skip.field.rrs_off, 25);
    try std.testing.expect(!cache.quiet());
}

test "vector zero is an ordinary vector, not an empty cache" {
    var cache = skip.Cache{};
    try std.testing.expect(!cache.holds(0));
    cache.keep(0, info(0x2200_0000, 0x2200_1000, 4));
    try std.testing.expect(cache.holds(0));
    try std.testing.expect(cache.fetch(skip.field.rrs_on, 0) != null);
}
