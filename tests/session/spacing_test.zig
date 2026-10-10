//! The gaps between stores: what counts as together, what counts as a
//! gap, and the shape a run of bursts prints as.
const std = @import("std");
const ra8 = @import("ra8");
const spacing = ra8.session.spacing;

test "one store opens no gap at all" {
    var gaps = spacing.Spacing{};
    gaps.record(417);
    try std.testing.expect(gaps.quiet());
    try std.testing.expectEqual(@as(usize, 0), gaps.together);
    try std.testing.expectEqual(@as(usize, 0), gaps.apart);
}

test "stores in one period are counted together" {
    var gaps = spacing.Spacing{};
    for (0..4) |_| gaps.record(3501);
    try std.testing.expectEqual(@as(usize, 3), gaps.together);
    try std.testing.expectEqual(@as(usize, 0), gaps.apart);
    try std.testing.expectEqual(@as(usize, 1), gaps.groups());
    try std.testing.expectEqual(@as(u64, 0), gaps.mean());
}

test "a gap records its width and widens the range" {
    var gaps = spacing.Spacing{};
    gaps.record(1);
    gaps.record(501);
    gaps.record(1001);
    try std.testing.expectEqual(@as(usize, 2), gaps.apart);
    try std.testing.expectEqual(@as(u64, 500), gaps.shortest);
    try std.testing.expectEqual(@as(u64, 500), gaps.longest);
    try std.testing.expectEqual(@as(u64, 500), gaps.mean());
    try std.testing.expectEqual(@as(usize, 3), gaps.groups());
}

test "bursts separated by gaps divide into groups" {
    var gaps = spacing.Spacing{};
    var period: u64 = 1;
    for (0..8) |_| {
        for (0..6) |_| gaps.record(period);
        period += 500;
    }
    try std.testing.expectEqual(@as(usize, 40), gaps.together);
    try std.testing.expectEqual(@as(usize, 7), gaps.apart);
    try std.testing.expectEqual(@as(usize, 8), gaps.groups());
    try std.testing.expectEqual(@as(u64, 500), gaps.mean());
}

test "a period that goes backwards is treated as no gap" {
    var gaps = spacing.Spacing{};
    gaps.record(900);
    gaps.record(100);
    try std.testing.expectEqual(@as(usize, 1), gaps.together);
    try std.testing.expectEqual(@as(usize, 0), gaps.apart);
    try std.testing.expectEqual(@as(u64, 100), gaps.last);
}
