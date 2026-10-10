//! tests/chip/periph/spi/enable_lock_test.zig covers src/chip/periph/spi/enable_lock.zig:
//! the rule that SPCR2 only takes a store while SPCR.SPE is clear.

const std = @import("std");
const ra8 = @import("ra8");
const lock = ra8.chip.periph.spi_enable_lock;

test "a stopped channel takes the store" {
    var locked = lock.Locked{};
    try std.testing.expect(locked.takes(false));
    try std.testing.expectEqual(@as(u32, 0), locked.ignored);
}

test "a running channel does not" {
    var locked = lock.Locked{};
    try std.testing.expect(!locked.takes(true));
    try std.testing.expectEqual(@as(u32, 1), locked.ignored);
}

test "every refused store is counted" {
    var locked = lock.Locked{};
    _ = locked.takes(true);
    _ = locked.takes(true);
    _ = locked.takes(false);
    _ = locked.takes(true);
    try std.testing.expectEqual(@as(u32, 3), locked.ignored);
}

test "a fresh lock is quiet and a refusal breaks the quiet" {
    var locked = lock.Locked{};
    try std.testing.expect(locked.quiet());
    _ = locked.takes(false);
    try std.testing.expect(locked.quiet());
    _ = locked.takes(true);
    try std.testing.expect(!locked.quiet());
}
