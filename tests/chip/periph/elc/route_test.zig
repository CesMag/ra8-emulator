//! Tests for src/chip/periph/elc/route.zig.
const std = @import("std");
const route = @import("ra8").chip.periph.elc_route;

fn linked(pairs: []const struct { usize, u16 }) route.Table {
    var table = route.Table{};
    for (pairs) |pair| table.latch(pair[0], pair[1]);
    return table;
}

test "a fresh table is quiet, links nothing and takes nothing" {
    var table = route.Table{};
    try std.testing.expect(table.quiet());
    try std.testing.expectEqual(@as(u32, 0), table.programmed());
    try std.testing.expectEqual(@as(?usize, null), table.firstTaker(0x120));
}

test "a latched slot reports its source through the ELS mask" {
    var table = route.Table{};
    table.latch(7, 0xFC23);
    try std.testing.expectEqual(@as(u16, 0x023), table.source(7));
    try std.testing.expectEqual(@as(u32, 1), table.programmed());
    try std.testing.expect(!table.quiet());
}

test "a slot index past the table is dropped rather than wrapping" {
    var table = route.Table{};
    table.latch(route.slots, 0x123);
    try std.testing.expectEqual(@as(u32, 0), table.programmed());
    try std.testing.expectEqual(@as(u16, 0), table.source(route.slots));
    try std.testing.expectEqual(@as(u32, 0), table.arrivalsAt(route.slots));
}

test "event zero is link disabled, so slots holding zero take nothing" {
    var table = route.Table{};
    try std.testing.expectEqual(@as(usize, 0), table.takers(0).len);
    try std.testing.expectEqual(route.Arrival.unrouted, table.offer(0, true));
    try std.testing.expectEqual(@as(u32, 0), table.delivered);
}

test "an offered event no slot links is unrouted" {
    var table = linked(&.{.{ 3, 0x120 }});
    try std.testing.expectEqual(route.Arrival.unrouted, table.offer(0x121, true));
    try std.testing.expectEqual(@as(u32, 1), table.offered);
    try std.testing.expectEqual(@as(u32, 1), table.unrouted);
    try std.testing.expectEqual(@as(u32, 0), table.arrivalsAt(3));
}

test "an offered event a slot links arrives at that slot" {
    var table = linked(&.{.{ 3, 0x120 }});
    try std.testing.expectEqual(route.Arrival.conducted, table.offer(0x120, true));
    try std.testing.expectEqual(@as(u32, 1), table.arrivalsAt(3));
    try std.testing.expectEqual(@as(u32, 1), table.delivered);
    try std.testing.expectEqual(@as(u32, 0), table.unrouted);
}

test "two slots on one source both take it, and the event conducts once" {
    var table = linked(&.{ .{ 3, 0x120 }, .{ 40, 0x120 } });
    try std.testing.expectEqual(route.Arrival.conducted, table.offer(0x120, true));
    try std.testing.expectEqual(@as(u32, 1), table.arrivalsAt(3));
    try std.testing.expectEqual(@as(u32, 1), table.arrivalsAt(40));
    try std.testing.expectEqual(@as(u32, 2), table.delivered);
    try std.testing.expectEqual(@as(u32, 1), table.offered);
    try std.testing.expectEqual(@as(u32, 2), table.busySlots());
}

test "takers answers the whole set, firstTaker only the lowest slot" {
    var table = linked(&.{ .{ 40, 0x120 }, .{ 3, 0x120 }, .{ 9, 0x121 } });
    const found = table.takers(0x120);
    try std.testing.expectEqual(@as(usize, 2), found.len);
    try std.testing.expectEqual(@as(u8, 3), found.get(0));
    try std.testing.expectEqual(@as(u8, 40), found.get(1));
    try std.testing.expectEqual(@as(?usize, 3), table.firstTaker(0x120));
}

test "a linked event offered with the block off is blocked, not delivered" {
    var table = linked(&.{.{ 3, 0x120 }});
    try std.testing.expectEqual(route.Arrival.blocked, table.offer(0x120, false));
    try std.testing.expectEqual(@as(u32, 1), table.blocked);
    try std.testing.expectEqual(@as(u32, 0), table.delivered);
    try std.testing.expectEqual(@as(u32, 0), table.arrivalsAt(3));
    try std.testing.expect(!table.quiet());
}

test "an unrouted event with the block off is unrouted, not blocked" {
    var table = linked(&.{.{ 3, 0x120 }});
    try std.testing.expectEqual(route.Arrival.unrouted, table.offer(0x121, false));
    try std.testing.expectEqual(@as(u32, 0), table.blocked);
    try std.testing.expectEqual(@as(u32, 1), table.unrouted);
}

test "unlinking a slot stops it taking the source it used to" {
    var table = linked(&.{.{ 3, 0x120 }});
    _ = table.offer(0x120, true);
    table.latch(3, 0);
    try std.testing.expectEqual(route.Arrival.unrouted, table.offer(0x120, true));
    try std.testing.expectEqual(@as(u32, 1), table.arrivalsAt(3));
    try std.testing.expectEqual(@as(u32, 0), table.programmed());
}

test "arrivals accumulate per slot across offers" {
    var table = linked(&.{ .{ 0, 0x080 }, .{ 52, 0x081 } });
    _ = table.offer(0x080, true);
    _ = table.offer(0x080, true);
    _ = table.offer(0x081, true);
    try std.testing.expectEqual(@as(u32, 2), table.arrivalsAt(0));
    try std.testing.expectEqual(@as(u32, 1), table.arrivalsAt(52));
    try std.testing.expectEqual(@as(u32, 3), table.delivered);
    try std.testing.expectEqual(@as(u32, 2), table.busySlots());
}

test "the last slot is reachable, so the table is 53 wide and not 52" {
    var table = route.Table{};
    table.latch(route.slots - 1, 0x0CC);
    try std.testing.expectEqual(route.Arrival.conducted, table.offer(0x0CC, true));
    try std.testing.expectEqual(@as(u32, 1), table.arrivalsAt(route.slots - 1));
}

test "every slot may take the same source without overflowing the set" {
    var table = route.Table{};
    for (0..route.slots) |index| table.latch(index, 0x0CC);
    try std.testing.expectEqual(@as(usize, route.slots), table.takers(0x0CC).len);
    try std.testing.expectEqual(route.Arrival.conducted, table.offer(0x0CC, true));
    try std.testing.expectEqual(@as(u32, route.slots), table.delivered);
}

test "a table that only ever saw unrouted events stays quiet" {
    var table = route.Table{};
    _ = table.offer(0x120, true);
    try std.testing.expect(table.quiet());
}
