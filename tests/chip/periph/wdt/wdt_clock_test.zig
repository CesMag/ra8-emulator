//! WDT0's count rate: the bench reading and the six legal dividers.
const std = @import("std");
const ra8 = @import("ra8");

const clock = ra8.chip.periph.wdt.clock;

test "CKS /4 counts at the bench's 40 Hz: 500 ticks of 50000 instructions" {
    try std.testing.expectEqual(@as(u32, 500), clock.ticksPerCount(0x1));
}

test "the six legal encodings decode to the dividers ra8_wdt.h names" {
    const pairs = [_][2]u32{ .{ 0x1, 4 }, .{ 0x4, 64 }, .{ 0xF, 128 }, .{ 0x6, 512 }, .{ 0x7, 2048 }, .{ 0x8, 8192 } };
    for (pairs) |pair| try std.testing.expectEqual(pair[1], clock.divider(@intCast(pair[0])));
}

test "a larger divider counts proportionally slower" {
    try std.testing.expectEqual(clock.ticksPerCount(0x1) * 2048, clock.ticksPerCount(0x8));
}

test "a prohibited encoding counts at the bench rate" {
    try std.testing.expectEqual(clock.ticksPerCount(0x1), clock.ticksPerCount(0x0));
    try std.testing.expectEqual(clock.ticksPerCount(0x1), clock.ticksPerCount(0x2));
}

test "a WDT underflow lands on the tick its due time names" {
    const wdt = ra8.chip.periph.wdt;
    try std.testing.expectEqual(@as(u64, 50_000), clock.ns_per_tick);
    var unit = wdt.Wdt.init();
    try std.testing.expectEqual(@as(?u64, null), unit.underflowDueAt(0));
    unit.wdtcr = wdt.controlWord(0, 0x1, 3, 3);
    unit.armed = true;
    unit.counter = 3;
    unit.pace = 120;
    // Four counts of 500 ticks, less the 120 already paced.
    const due = unit.underflowDueAt(7).?;
    try std.testing.expectEqual(@as(u64, 7 + (4 * 500 - 120) * 50_000), due);
    var now: u64 = 7;
    while (now + clock.ns_per_tick < due) : (now += clock.ns_per_tick) {
        unit.tick();
        try std.testing.expectEqual(@as(u32, 0), unit.underflows);
    }
    unit.tick();
    try std.testing.expectEqual(@as(u32, 1), unit.underflows);
}

test "short boundaries carry their ns until they add up to one tick" {
    var carry: u64 = 0;
    var total: u64 = 0;
    for (0..24) |_| total += clock.ticksIn(&carry, 2_000);
    try std.testing.expectEqual(@as(u64, 0), total);
    try std.testing.expectEqual(@as(u64, 1), clock.ticksIn(&carry, 2_000));
    try std.testing.expectEqual(@as(u64, 0), carry);
    try std.testing.expectEqual(@as(u64, 3), clock.ticksIn(&carry, 3 * clock.ns_per_tick + 5));
    try std.testing.expectEqual(@as(u64, 5), carry);
}

test "the WDT counts the virtual ns that passed, not the boundaries" {
    const wdt = ra8.chip.periph.wdt;
    var unit = wdt.Wdt.init();
    unit.wdtcr = wdt.controlWord(0, 0x1, 3, 3);
    unit.armed = true;
    unit.counter = 3;
    for (0..25 * 499) |_| unit.tickFor(2_000);
    try std.testing.expectEqual(@as(u32, 3), unit.counter);
    unit.tickFor(25 * 2_000);
    try std.testing.expectEqual(@as(u32, 2), unit.counter);
}

test "an armed WDT puts its underflow on the queue under its own id, a disarmed one takes it off" {
    const wdt = ra8.chip.periph.wdt;
    var queue = ra8.chip.periph.clocks.event_queue.EventQueue{};
    var unit = wdt.Wdt.init();
    try unit.arm(&queue, 0);
    try std.testing.expectEqual(@as(?u64, null), queue.next());
    unit.wdtcr = wdt.controlWord(0, 0x1, 3, 3);
    unit.armed = true;
    unit.counter = 3;
    try unit.arm(&queue, 100);
    try std.testing.expectEqual(unit.underflowDueAt(100), queue.next());
    try std.testing.expectEqual(clock.queue_id.wdt, queue.items[0].id);
    // A refresh moves it rather than stacking a second entry.
    unit.counter = 9;
    try unit.arm(&queue, 200);
    try std.testing.expectEqual(@as(usize, 1), queue.count);
    try std.testing.expectEqual(unit.underflowDueAt(200), queue.next());
    unit.armed = false;
    try unit.arm(&queue, 300);
    try std.testing.expectEqual(@as(usize, 0), queue.count);
}

fn windowed(pace: u32) ra8.chip.periph.wdt.Wdt {
    const wdt = ra8.chip.periph.wdt;
    var unit = wdt.Wdt.init();
    // wdt_window_demo's window: 1024 counts, /4, open 768 down to 256.
    unit.wdtcr = wdt.controlWord(0, 0x1, 2, 2);
    unit.armed = true;
    unit.counter = unit.reload();
    unit.pace = pace;
    return unit;
}

test "the WDT window opens and closes at the virtual ns its edges name" {
    var unit = windowed(120);
    const edges = unit.windowEdgesAt(9);
    try std.testing.expectEqual(@as(?u64, 9 + ((1023 - 768) * 500 - 120) * 50_000), edges.opens_at);
    try std.testing.expectEqual(@as(?u64, 9 + ((1023 - 255) * 500 - 120) * 50_000), edges.closes_at);
    var now: u64 = 9;
    while (now < edges.closes_at.?) : (now += clock.ns_per_tick) {
        const inside = now >= edges.opens_at.?;
        try std.testing.expectEqual(inside, unit.windowOpen());
        unit.tick();
    }
    try std.testing.expect(!unit.windowOpen());
}

test "a window open to underflow has no closing edge, and a disarmed WDT has neither" {
    const wdt = ra8.chip.periph.wdt;
    var unit = windowed(0);
    unit.wdtcr = wdt.controlWord(0, 0x1, 2, 3);
    try std.testing.expect(unit.windowEdgesAt(0).opens_at != null);
    try std.testing.expectEqual(@as(?u64, null), unit.windowEdgesAt(0).closes_at);
    unit.counter = 700;
    try std.testing.expectEqual(@as(?u64, null), unit.windowEdgesAt(0).opens_at);
    unit.armed = false;
    try std.testing.expectEqual(wdt.WindowEdges{}, unit.windowEdgesAt(0));
}

test "the WDT queues its next window edge beside its underflow" {
    var queue = ra8.chip.periph.clocks.event_queue.EventQueue{};
    var unit = windowed(0);
    try unit.arm(&queue, 0);
    try std.testing.expectEqual(@as(usize, 2), queue.count);
    try std.testing.expectEqual(unit.windowEdgesAt(0).opens_at, queue.next());
    try std.testing.expectEqual(clock.queue_id.wdt_window, queue.items[0].id);
    // Inside the window the next edge is where it closes.
    unit.counter = 500;
    try unit.arm(&queue, 0);
    try std.testing.expectEqual(@as(usize, 2), queue.count);
    try std.testing.expectEqual(unit.windowEdgesAt(0).closes_at, queue.next());
}
