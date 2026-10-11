//! The table every watchpoint in a session lives in.
const std = @import("std");
const ra8 = @import("ra8");
const watch_table = ra8.session.watch.table;
const Watch = watch_table.Watch;

test "an empty range is refused" {
    try std.testing.expectError(error.EmptyRange, Watch.span(0x2000_0000, 0, .write));
}

test "a write watch stops on a write and ignores a read" {
    var table = watch_table.Table{};
    const id = try table.add(try Watch.span(0x2000_0010, 4, .write));
    try std.testing.expectEqual(@as(?watch_table.Hit, null), table.hit(0x2000_0010, 4, .read));
    const got = table.hit(0x2000_0012, 1, .write).?;
    try std.testing.expectEqual(id, got.id);
    try std.testing.expectEqual(@as(u32, 0x2000_0012), got.address);
}

test "a read watch stops on a read and ignores a write" {
    var table = watch_table.Table{};
    _ = try table.add(try Watch.span(0x2000_0010, 4, .read));
    try std.testing.expectEqual(@as(?watch_table.Hit, null), table.hit(0x2000_0010, 4, .write));
    try std.testing.expect(table.hit(0x2000_0010, 4, .read) != null);
}

test "an access watch stops on either" {
    var table = watch_table.Table{};
    _ = try table.add(try Watch.span(0x2000_0010, 4, .access));
    try std.testing.expect(table.hit(0x2000_0010, 4, .write) != null);
    try std.testing.expect(table.hit(0x2000_0010, 4, .read) != null);
}

test "an access that straddles the range edge still overlaps" {
    var table = watch_table.Table{};
    _ = try table.add(try Watch.span(0x2000_0010, 4, .write));
    try std.testing.expect(table.hit(0x2000_000E, 4, .write) != null);
    try std.testing.expect(table.hit(0x2000_0013, 2, .write) != null);
    try std.testing.expectEqual(@as(?watch_table.Hit, null), table.hit(0x2000_000C, 4, .write));
    try std.testing.expectEqual(@as(?watch_table.Hit, null), table.hit(0x2000_0014, 4, .write));
}

test "every matching watch counts, the first set reports" {
    var table = watch_table.Table{};
    const first = try table.add(try Watch.span(0x2000_0010, 8, .access));
    const second = try table.add(try Watch.span(0x2000_0014, 4, .write));
    const got = table.hit(0x2000_0014, 4, .write).?;
    try std.testing.expectEqual(first, got.id);
    try std.testing.expectEqual(@as(u32, 1), table.get(second).?.seen);
}

test "a disabled watch neither counts nor stops" {
    var table = watch_table.Table{};
    const id = try table.add(try Watch.span(0x2000_0010, 4, .write));
    try table.setEnabled(id, false);
    try std.testing.expectEqual(@as(?watch_table.Hit, null), table.hit(0x2000_0010, 4, .write));
    try std.testing.expectEqual(@as(u32, 0), table.get(id).?.seen);
}

test "a range at the top of the address space does not wrap" {
    const watch = try Watch.span(0xFFFF_FFFC, 16, .write);
    try std.testing.expectEqual(@as(u32, 0xFFFF_FFFF), watch.last);
    try std.testing.expect(!watch.overlaps(0x0000_0000, 4));
}

test "removing a watch keeps the rest and refuses a stale id" {
    var table = watch_table.Table{};
    const first = try table.add(try Watch.span(0x10, 4, .write));
    const second = try table.add(try Watch.span(0x20, 4, .write));
    try table.remove(first);
    try std.testing.expectEqual(second, table.entries()[0].id);
    try std.testing.expectError(error.NoSuchWatch, table.remove(first));
}
