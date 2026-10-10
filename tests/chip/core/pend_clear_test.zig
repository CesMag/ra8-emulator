const std = @import("std");
const ra8 = @import("ra8");
const pend_clear = ra8.chip.core.pend_clear;

test "a fresh counter is quiet" {
    const cleared = pend_clear.Cleared{};
    try std.testing.expect(cleared.quiet());
    try std.testing.expectEqual(@as(usize, 0), cleared.silent());
}

test "the first store places the address and is not counted as elsewhere" {
    var cleared = pend_clear.Cleared{};
    cleared.record(0x0200_54D0, 0, false);
    try std.testing.expect(!cleared.quiet());
    try std.testing.expectEqual(@as(usize, 1), cleared.count);
    try std.testing.expectEqual(@as(u32, 0x0200_54D0), cleared.first_at);
    try std.testing.expectEqual(@as(usize, 0), cleared.elsewhere);
}

test "a repeat of the same address is not elsewhere" {
    var cleared = pend_clear.Cleared{};
    cleared.record(0x0200_54D0, 0, false);
    cleared.record(0x0200_54D0, 0, false);
    try std.testing.expectEqual(@as(usize, 2), cleared.count);
    try std.testing.expectEqual(@as(usize, 0), cleared.elsewhere);
}

test "a different address is counted as elsewhere" {
    var cleared = pend_clear.Cleared{};
    cleared.record(0x0200_54D0, 0, false);
    cleared.record(0x0200_6BF8, 0, false);
    try std.testing.expectEqual(@as(usize, 1), cleared.elsewhere);
}

test "a store inside a handler is told apart from a thread-mode one" {
    var cleared = pend_clear.Cleared{};
    cleared.record(0x0200_54D0, 0, false);
    cleared.record(0x0200_54D0, 14, false);
    try std.testing.expectEqual(@as(usize, 1), cleared.in_handler);
}

test "a store naming PENDSVCLR asked for the clear and is not silent" {
    var cleared = pend_clear.Cleared{};
    cleared.record(0x0200_54D0, 0, true);
    try std.testing.expectEqual(@as(usize, 1), cleared.asked);
    try std.testing.expectEqual(@as(usize, 0), cleared.silent());
}

test "silent counts only the stores that never named the clear bit" {
    var cleared = pend_clear.Cleared{};
    cleared.record(0x0200_54D0, 0, true);
    cleared.record(0x0200_54D0, 0, false);
    cleared.record(0x0200_54D0, 0, false);
    try std.testing.expectEqual(@as(usize, 3), cleared.count);
    try std.testing.expectEqual(@as(usize, 2), cleared.silent());
}
