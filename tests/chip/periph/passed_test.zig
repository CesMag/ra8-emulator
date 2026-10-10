//! Tests for src/chip/periph/passed.zig.
const std = @import("std");
const ra8 = @import("ra8");
const passed = ra8.chip.periph.passed;

test "a fresh tally is quiet" {
    const tally = passed.Passed{};
    try std.testing.expect(tally.quiet());
    try std.testing.expectEqual(@as(u16, 0), tally.loser);
}

test "the first loss keeps the pairing" {
    var tally = passed.Passed{};
    tally.lost(14, 15);
    tally.lost(20, 15);
    try std.testing.expectEqual(@as(u64, 2), tally.losses);
    try std.testing.expectEqual(@as(u16, 14), tally.loser);
    try std.testing.expectEqual(@as(u16, 15), tally.winner);
}

test "the same loser losing twice running is a run of two" {
    var tally = passed.Passed{};
    tally.lost(14, 15);
    tally.lost(14, 15);
    try std.testing.expectEqual(@as(u64, 2), tally.run);
    try std.testing.expectEqual(@as(u64, 2), tally.longest);
    try std.testing.expectEqual(@as(u16, 14), tally.starved);
}

test "a boundary that lost nothing ends the run but keeps the longest" {
    var tally = passed.Passed{};
    tally.lost(14, 15);
    tally.boundary();
    tally.lost(14, 15);
    tally.boundary();
    try std.testing.expectEqual(@as(u64, 2), tally.run);
    tally.boundary();
    try std.testing.expectEqual(@as(u64, 0), tally.run);
    try std.testing.expectEqual(@as(u64, 2), tally.longest);
}

test "consecutive losing boundaries keep the run going" {
    var tally = passed.Passed{};
    var n: usize = 0;
    while (n < 5) : (n += 1) {
        tally.lost(14, 15);
        tally.boundary();
    }
    try std.testing.expectEqual(@as(u64, 5), tally.run);
    try std.testing.expectEqual(@as(u64, 5), tally.longest);
}

test "a different loser restarts the run" {
    var tally = passed.Passed{};
    tally.lost(14, 15);
    tally.lost(14, 15);
    tally.lost(20, 15);
    try std.testing.expectEqual(@as(u64, 1), tally.run);
    try std.testing.expectEqual(@as(u64, 2), tally.longest);
    try std.testing.expectEqual(@as(u16, 20), tally.starved);
}
