//! Tests for src/session/tally.zig.
const std = @import("std");
const ra8 = @import("ra8");
const tally_mod = ra8.session.tally;

test "the same site and value fold into one row" {
    var tally = tally_mod.Tally{};
    for (0..452) |_| tally.record(0x0200_22A6, 1);
    try std.testing.expectEqual(@as(usize, 1), tally.used);
    try std.testing.expectEqual(@as(u64, 452), tally.sites[0].writes);
    try std.testing.expectEqual(@as(u64, 0), tally.displaced);
}

test "one site writing two values keeps them apart" {
    var tally = tally_mod.Tally{};
    tally.record(0x0200_2E20, 2);
    tally.record(0x0200_2E20, 2);
    tally.record(0x0200_2E20, 1);
    try std.testing.expectEqual(@as(usize, 2), tally.used);
    var room: [tally_mod.limits.kept]tally_mod.Site = undefined;
    const ranked = tally.ranked(&room);
    try std.testing.expectEqual(@as(u32, 2), ranked[0].value);
    try std.testing.expectEqual(@as(u64, 2), ranked[0].writes);
    try std.testing.expectEqual(@as(u32, 1), ranked[1].value);
}

test "the pairing that located the freeze reads off the tally" {
    var tally = tally_mod.Tally{};
    for (0..452) |_| tally.record(0x0200_22A6, 1);
    for (0..451) |_| tally.record(0x0200_232C, 0);
    var room: [tally_mod.limits.kept]tally_mod.Site = undefined;
    const ranked = tally.ranked(&room);
    try std.testing.expectEqual(@as(u64, 452), ranked[0].writes);
    try std.testing.expectEqual(@as(u64, 451), ranked[1].writes);
    // One increment with no matching decrement, which is the whole finding.
    try std.testing.expectEqual(@as(u64, 1), ranked[0].writes - ranked[1].writes);
}

test "a full table displaces its weakest row and says so" {
    var tally = tally_mod.Tally{};
    for (0..tally_mod.limits.kept) |index| tally.record(@intCast(0x1000 + index * 4), 0);
    for (0..9) |_| tally.record(0x1000, 0);
    tally.record(0xDEAD, 7);
    try std.testing.expectEqual(tally_mod.limits.kept, tally.used);
    try std.testing.expectEqual(@as(u64, 1), tally.displaced);
    // The busy row survived; a one-write row went.
    var room: [tally_mod.limits.kept]tally_mod.Site = undefined;
    try std.testing.expectEqual(@as(u32, 0x1000), tally.ranked(&room)[0].pc);
}

test "a place written once has no tally worth printing" {
    var tally = tally_mod.Tally{};
    try std.testing.expect(tally.quiet());
    tally.record(0x1000, 1);
    try std.testing.expect(tally.quiet());
    tally.record(0x1000, 1);
    try std.testing.expect(!tally.quiet());
}

test "an exception entry tally keys the interrupted pc against the vector" {
    var counted = tally_mod.Tally{};
    // SysTick taken repeatedly in the same spin, and once somewhere else.
    for (0..111) |_| counted.record(0x0200_227C, 15);
    for (0..1000) |_| counted.record(0x0200_02A4, 15);
    counted.record(0x0200_02A4, 14);
    try std.testing.expectEqual(@as(usize, 3), counted.used);
    var room: [tally_mod.limits.kept]tally_mod.Site = undefined;
    const ranked = counted.ranked(&room);
    try std.testing.expectEqual(@as(u64, 1000), ranked[0].writes);
    try std.testing.expectEqual(@as(u32, 15), ranked[0].value);
    // The same pc under a different vector stays its own row, which is the
    // whole reason the key is a pair.
    try std.testing.expectEqual(@as(u32, 14), ranked[2].value);
    try std.testing.expectEqual(@as(u32, 0x0200_02A4), ranked[2].pc);
}

test "a one-off row is what a full tally loses" {
    var counted = tally_mod.Tally{};
    // Fill with busy rows, then offer the rare entry this tally cannot keep.
    for (0..tally_mod.limits.kept) |index| {
        for (0..50) |_| counted.record(@intCast(0x1000 + index * 4), 15);
    }
    counted.record(0x0200_22B6, 14);
    try std.testing.expectEqual(@as(u64, 1), counted.displaced);
    // It reports the loss rather than hiding it, so a tally that is not the
    // whole story says so.
    var room: [tally_mod.limits.kept]tally_mod.Site = undefined;
    for (counted.ranked(&room)) |site| {
        try std.testing.expect(site.pc != 0x0200_22B6 or site.writes == 1);
    }
}

test "an empty tally ranks to nothing" {
    const empty: tally_mod.Tally = .{};
    var room: [tally_mod.limits.kept]tally_mod.Site = undefined;
    try std.testing.expectEqual(@as(usize, 0), empty.ranked(&room).len);
}
