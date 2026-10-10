//! The latch behind HUM Ch 27.3.2: one write per control register, ever.
const std = @import("std");
const ra8 = @import("ra8");

const write_once = ra8.chip.periph.wdt.write_once;

test "a fresh latch has nothing written and gives every register its write" {
    var once = write_once.Once{};
    try std.testing.expect(once.quiet());
    try std.testing.expect(!once.taken(.control));
    try std.testing.expect(once.claim(.control));
    try std.testing.expect(once.claim(.reset_control));
    try std.testing.expect(once.claim(.count_stop));
}

test "the second claim on a register is refused and the latch stays taken" {
    var once = write_once.Once{};
    try std.testing.expect(once.claim(.reset_control));
    try std.testing.expect(!once.claim(.reset_control));
    try std.testing.expect(!once.claim(.reset_control));
    try std.testing.expect(once.taken(.reset_control));
}

test "the three registers are latched independently" {
    var once = write_once.Once{};
    try std.testing.expect(once.claim(.control));
    try std.testing.expect(!once.taken(.reset_control));
    try std.testing.expect(!once.taken(.count_stop));
    try std.testing.expect(once.claim(.count_stop));
    try std.testing.expect(!once.taken(.reset_control));
}

test "any claim at all takes the latch out of quiet" {
    var once = write_once.Once{};
    try std.testing.expect(once.claim(.count_stop));
    try std.testing.expect(!once.quiet());
}
