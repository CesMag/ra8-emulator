//! Covers src/chip/periph/time/timebase.zig: virtual ns from cycles and a rate.
const std = @import("std");
const ra8 = @import("ra8");
const time = ra8.chip.periph.clocks.timebase;

const TimeBase = time.TimeBase;

test "a run starts at zero and counts one ns per cycle at 1 GHz" {
    var base = TimeBase{};
    try std.testing.expectEqual(@as(u64, 0), base.now());
    base.advance(1500);
    try std.testing.expectEqual(@as(u64, 1500), base.now());
}

test "a slow clock adds no drift over a long run" {
    var base = TimeBase{ .hz = 120_000_000 };
    // A week at 120 MHz, in chunks that do not divide the rate evenly.
    const week_cycles: u64 = 120_000_000 * 60 * 60 * 24 * 7;
    var left = week_cycles;
    while (left > 0) {
        const step = @min(left, 999_999_937);
        base.advance(step);
        left -= step;
    }
    try std.testing.expectEqual(@as(u64, 60 * 60 * 24 * 7) * time.ns_per_s, base.now());
}

test "a rate change keeps the time already gone by" {
    var base = TimeBase{};
    base.advance(2000);
    base.setRate(250_000_000);
    base.advance(250);
    try std.testing.expectEqual(@as(u64, 3000), base.now());
    try std.testing.expectEqual(@as(u64, 2250), base.retired);
}

test "a zero rate is ignored" {
    var base = TimeBase{};
    base.setRate(0);
    base.advance(10);
    try std.testing.expectEqual(@as(u64, 10), base.now());
}

test "cyclesUntil lands on the first cycle at or past the target" {
    var base = TimeBase{ .hz = 3 };
    base.advance(1);
    const due = time.ns_per_s;
    const cycles = base.cyclesUntil(due);
    try std.testing.expectEqual(@as(u64, 2), cycles);
    base.advance(cycles - 1);
    try std.testing.expect(base.now() < due);
    base.advance(1);
    try std.testing.expect(base.now() >= due);
    try std.testing.expectEqual(@as(u64, 0), base.cyclesUntil(due));
}

test "the board's clock starts at zero with nothing scheduled" {
    const clock = ra8.chip.periph.clocks.Time{};
    try std.testing.expectEqual(@as(u64, 0), clock.base.now());
    try std.testing.expect(clock.queue.next() == null);
}
