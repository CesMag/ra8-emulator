//! The table every breakpoint in a session lives in.
const std = @import("std");
const ra8 = @import("ra8");
const break_table = ra8.session.breaks.table;

test "an empty table stops nowhere" {
    var table = break_table.Table{};
    try std.testing.expectEqual(@as(?break_table.Id, null), table.hit(0x0200_1000));
}

test "a break by address stops on its first arrival" {
    var table = break_table.Table{};
    const id = try table.add(.{ .address = 0x0200_1000 });
    try std.testing.expectEqual(@as(?break_table.Id, id), table.hit(0x0200_1000));
}

test "the Thumb bit is ignored on both sides" {
    var table = break_table.Table{};
    const id = try table.add(.{ .address = 0x0200_1001 });
    try std.testing.expectEqual(@as(?break_table.Id, id), table.hit(0x0200_1000));
    try std.testing.expectEqual(@as(?break_table.Id, id), table.find(0x0200_1001));
}

test "a counted break waits for its arrival, then stops on every one after" {
    var table = break_table.Table{};
    const id = try table.add(.{ .address = 0x0200_1000, .arrival = 3 });
    try std.testing.expectEqual(@as(?break_table.Id, null), table.hit(0x0200_1000));
    try std.testing.expectEqual(@as(?break_table.Id, null), table.hit(0x0200_1000));
    try std.testing.expectEqual(@as(?break_table.Id, id), table.hit(0x0200_1000));
    try std.testing.expectEqual(@as(?break_table.Id, id), table.hit(0x0200_1000));
    try std.testing.expectEqual(@as(u32, 4), table.get(id).?.seen);
}

test "a second break on one address is refused" {
    var table = break_table.Table{};
    _ = try table.add(.{ .address = 0x0200_1000 });
    try std.testing.expectError(error.AlreadySet, table.add(.{ .address = 0x0200_1001 }));
}

test "a disabled break neither counts nor stops" {
    var table = break_table.Table{};
    const id = try table.add(.{ .address = 0x0200_1000 });
    try table.setEnabled(id, false);
    try std.testing.expectEqual(@as(?break_table.Id, null), table.hit(0x0200_1000));
    try std.testing.expectEqual(@as(u32, 0), table.get(id).?.seen);
}

test "removing keeps the others in the order they were set" {
    var table = break_table.Table{};
    const first = try table.add(.{ .address = 0x10 });
    const second = try table.add(.{ .address = 0x20 });
    const third = try table.add(.{ .address = 0x30 });
    try table.remove(second);
    try std.testing.expectEqual(@as(usize, 2), table.entries().len);
    try std.testing.expectEqual(first, table.entries()[0].id);
    try std.testing.expectEqual(third, table.entries()[1].id);
    try std.testing.expectError(error.NoSuchBreak, table.remove(second));
}

test "ids are not reused after a remove" {
    var table = break_table.Table{};
    const first = try table.add(.{ .address = 0x10 });
    try table.remove(first);
    const again = try table.add(.{ .address = 0x10 });
    try std.testing.expect(again != first);
}

test "a full table refuses another break" {
    var table = break_table.Table{};
    var at: u32 = 0;
    while (at < break_table.limits.capacity) : (at += 1) _ = try table.add(.{ .address = at * 4 });
    try std.testing.expectError(error.TableFull, table.add(.{ .address = 0xFFFF_0000 }));
}
