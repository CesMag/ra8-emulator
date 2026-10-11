//! Tests for src/chip/periph/candidate.zig.
const std = @import("std");
const ra8 = @import("ra8");
const candidate = ra8.chip.periph.candidate;

test "the first candidate wins against nothing" {
    const won = candidate.better(null, .{ .number = 15, .priority = 0x40 });
    try std.testing.expectEqual(@as(u16, 15), won.number);
}

test "lower priority is more urgent" {
    const won = candidate.better(
        .{ .number = 14, .priority = 0xFF },
        .{ .number = 15, .priority = 0x40 },
    );
    try std.testing.expectEqual(@as(u16, 15), won.number);
}

test "a tie goes to the lower exception number" {
    const won = candidate.better(
        .{ .number = 15, .priority = 0x40 },
        .{ .number = 14, .priority = 0x40 },
    );
    try std.testing.expectEqual(@as(u16, 14), won.number);
}

test "nothing loses when there was no standing candidate" {
    const cand = candidate.Candidate{ .number = 15, .priority = 0x40 };
    try std.testing.expectEqual(@as(?candidate.Candidate, null), candidate.loser(null, cand, cand));
}

test "the loser is whichever one the winner is not" {
    const standing = candidate.Candidate{ .number = 14, .priority = 0xFF };
    const cand = candidate.Candidate{ .number = 15, .priority = 0x40 };
    const won = candidate.better(standing, cand);
    const lost = candidate.loser(standing, cand, won).?;
    try std.testing.expectEqual(@as(u16, 14), lost.number);
}

test "the standing candidate can be the one that loses nothing" {
    const standing = candidate.Candidate{ .number = 15, .priority = 0x40 };
    const cand = candidate.Candidate{ .number = 14, .priority = 0xFF };
    const won = candidate.better(standing, cand);
    const lost = candidate.loser(standing, cand, won).?;
    try std.testing.expectEqual(@as(u16, 15), won.number);
    try std.testing.expectEqual(@as(u16, 14), lost.number);
}

test {
    _ = @import("nvic/banked_test.zig");
}
