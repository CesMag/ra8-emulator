//! Covers src/chip/periph/standing.zig: the tally that says how long PendSV's
//! pend bit stood before anything took it. The run of consecutive unserved
//! boundaries is the number the whole counter exists for, so what is pinned
//! here is that it survives a gap, resets on an entry, and does not count a
//! boundary the bit was down at.
const std = @import("std");
const ra8 = @import("ra8");

const standing = ra8.chip.periph.standing;

test "a run that never pends PendSV says nothing" {
    var tally = standing.Standing{};
    tally.boundary(false);
    tally.boundary(false);
    try std.testing.expect(tally.quiet());
    try std.testing.expectEqual(@as(u64, 0), tally.boundaries);
}

test "a bit that stands over boundaries counts every one of them" {
    var tally = standing.Standing{};
    for (0..5) |_| tally.boundary(true);
    try std.testing.expectEqual(@as(u64, 5), tally.boundaries);
    try std.testing.expectEqual(@as(u64, 5), tally.worst);
    try std.testing.expectEqual(@as(u64, 5), tally.unserved());
}

test "entering the handler ends the run but keeps the boundary count" {
    var tally = standing.Standing{};
    tally.boundary(true);
    tally.boundary(true);
    tally.entered();
    tally.boundary(true);
    try std.testing.expectEqual(@as(u64, 3), tally.boundaries);
    try std.testing.expectEqual(@as(u64, 1), tally.entries);
    try std.testing.expectEqual(@as(u64, 2), tally.unserved());
    try std.testing.expectEqual(@as(u64, 2), tally.worst);
}

test "the worst run is the longest one, not the last" {
    var tally = standing.Standing{};
    for (0..7) |_| tally.boundary(true);
    tally.entered();
    tally.boundary(true);
    try std.testing.expectEqual(@as(u64, 7), tally.worst);
}

test "a boundary with the bit down breaks the run without being counted" {
    var tally = standing.Standing{};
    tally.boundary(true);
    tally.boundary(true);
    tally.boundary(false);
    tally.boundary(true);
    try std.testing.expectEqual(@as(u64, 3), tally.boundaries);
    try std.testing.expectEqual(@as(u64, 2), tally.worst);
}

test "a handler entered more often than the bit stood owes nothing" {
    var tally = standing.Standing{};
    tally.boundary(true);
    tally.entered();
    tally.entered();
    try std.testing.expectEqual(@as(u64, 0), tally.unserved());
}
