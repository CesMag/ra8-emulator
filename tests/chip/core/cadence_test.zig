const std = @import("std");
const ra8 = @import("ra8");

const cadence = ra8.chip.core.cadence;

test "the default boundary is narrower than dev's chunk" {
    try std.testing.expect(cadence.instructions < 500_000);
}

test "a whole boundary is taken when the budget allows" {
    const pace = cadence.Cadence{};
    try std.testing.expectEqual(@as(usize, cadence.instructions), pace.chunk(1_000_000));
}

test "the last stretch is what is left of the budget" {
    const pace = cadence.Cadence{ .per_boundary = 1000 };
    try std.testing.expectEqual(@as(usize, 250), pace.chunk(250));
}

test "a stretch exactly one boundary wide is one boundary" {
    const pace = cadence.Cadence{ .per_boundary = 1000 };
    try std.testing.expectEqual(@as(usize, 1000), pace.chunk(1000));
}

test "a spent budget closes no boundary" {
    const pace = cadence.Cadence{};
    try std.testing.expect(!pace.closes(0));
}

test "a budget with anything left closes one" {
    const pace = cadence.Cadence{};
    try std.testing.expect(pace.closes(1));
}

test "a budget of exactly one boundary ticks nothing" {
    const pace = cadence.Cadence{ .per_boundary = 1000 };
    try std.testing.expectEqual(@as(usize, 0), pace.boundaries(1000));
}

test "a budget of two boundaries ticks once" {
    const pace = cadence.Cadence{ .per_boundary = 1000 };
    try std.testing.expectEqual(@as(usize, 1), pace.boundaries(2000));
}

test "a partial last stretch still ticks after the whole ones" {
    const pace = cadence.Cadence{ .per_boundary = 1000 };
    try std.testing.expectEqual(@as(usize, 2), pace.boundaries(2500));
}

test "a budget shorter than one boundary ticks nothing" {
    const pace = cadence.Cadence{ .per_boundary = 1000 };
    try std.testing.expectEqual(@as(usize, 0), pace.boundaries(999));
}

test "an empty budget ticks nothing" {
    const pace = cadence.Cadence{ .per_boundary = 1000 };
    try std.testing.expectEqual(@as(usize, 0), pace.boundaries(0));
}

test "a zero boundary ticks nothing rather than dividing by it" {
    const pace = cadence.Cadence{ .per_boundary = 0 };
    try std.testing.expectEqual(@as(usize, 0), pace.boundaries(10_000));
}

test "the default budget passes through enough boundaries for a bounded poll" {
    const pace = cadence.Cadence{};
    // The timer image polls GTCNT 400000 times; at dev's 500000-wide chunk
    // the whole default budget was three ticks.
    try std.testing.expect(pace.boundaries(2_000_000) >= 20);
}

test "the clocks charge a boundary's worth of instructions per boundary" {
    try std.testing.expectEqual(cadence.instructions, ra8.chip.periph.clocks.chunk_instructions);
}

test "boundaries and chunks agree on how a budget is cut" {
    const pace = cadence.Cadence{ .per_boundary = 64 };
    var remaining: usize = 1000;
    var ticks: usize = 0;
    while (remaining > 0) {
        remaining -= pace.chunk(remaining);
        if (!pace.closes(remaining)) break;
        ticks += 1;
    }
    try std.testing.expectEqual(pace.boundaries(1000), ticks);
}

test "a boundary narrows to a period finer than it" {
    const pace = cadence.Cadence{ .per_boundary = 50_000 };
    try std.testing.expectEqual(@as(u32, 8_401), pace.narrowedTo(8_401).per_boundary);
}

test "a boundary is never widened to a longer period" {
    const pace = cadence.Cadence{ .per_boundary = 50_000 };
    try std.testing.expectEqual(@as(u32, 50_000), pace.narrowedTo(200_000).per_boundary);
    try std.testing.expectEqual(@as(u32, 50_000), pace.narrowedTo(50_000).per_boundary);
}

test "nothing armed leaves the boundary alone" {
    const pace = cadence.Cadence{ .per_boundary = 50_000 };
    try std.testing.expectEqual(@as(u32, 50_000), pace.narrowedTo(0).per_boundary);
}

test "a period under the floor narrows only to the floor" {
    const pace = cadence.Cadence{ .per_boundary = 50_000 };
    try std.testing.expectEqual(cadence.floor, pace.narrowedTo(1).per_boundary);
    try std.testing.expectEqual(cadence.floor, pace.narrowedTo(cadence.floor - 1).per_boundary);
}

test "a narrowed boundary delivers one period per chunk" {
    const pace = (cadence.Cadence{ .per_boundary = 50_000 }).narrowedTo(8_401);
    try std.testing.expectEqual(@as(usize, 8_401), pace.chunk(100_000));
}

test "an asked-for boundary wins over the time base" {
    const pace = cadence.configuredFrom(1_000, 50_000);
    try std.testing.expectEqual(@as(u32, 1_000), pace.per_boundary);
}

test "without one, the time base's own width is used" {
    const pace = cadence.configuredFrom(null, 7_500);
    try std.testing.expectEqual(@as(u32, 7_500), pace.per_boundary);
}

test "with neither, the default stands" {
    const pace = cadence.configuredFrom(null, null);
    try std.testing.expectEqual(cadence.instructions, pace.per_boundary);
}

test "a boundary of zero is refused, not honoured" {
    // A boundary every no instructions is a loop that never advances.
    const pace = cadence.configuredFrom(0, 9_000);
    try std.testing.expectEqual(@as(u32, 9_000), pace.per_boundary);
    try std.testing.expectEqual(cadence.instructions, cadence.configuredFrom(0, null).per_boundary);
}
