//! Tests for src/session/watch_link.zig: `--watch` matched through the stop
//! machine's watch table, recorded, and never stopping the run.
const std = @import("std");
const ra8 = @import("ra8");
const watchpoint = ra8.session.watchpoint;
const watch_link = ra8.session.step_hook.watch.link;

test "a store in the window is recorded with its pc and lr" {
    var watched = watchpoint.Watched{ .address = 0x2200_0040 };
    var made = watch_link.link(&watched);
    made.store(0x0200_0100, 0x0200_0201, 0x2200_0040, 4, 7);
    try std.testing.expectEqual(@as(usize, 1), watched.seen);
    const one = watched.opening()[0];
    try std.testing.expectEqual(@as(u32, 0x0200_0100), one.pc);
    try std.testing.expectEqual(@as(u32, 0x0200_0201), one.lr);
    try std.testing.expectEqual(@as(u32, 7), one.value);
    try std.testing.expectEqual(@as(u32, 1), made.seen());
}

test "a matching store leaves the machine running" {
    var watched = watchpoint.Watched{ .address = 0x2200_0040 };
    var made = watch_link.link(&watched);
    made.store(0x0200_0100, 0, 0x2200_0042, 2, 0xBEEF);
    try std.testing.expect(made.machine.watch_pending == null);
    const event = ra8.session.stop_machine.Event{ .pc = 0x0200_0104, .size = 2, .sp = 0 };
    try std.testing.expect(made.machine.onInstruction(event) == null);
}

test "a store outside the window is not recorded" {
    var watched = watchpoint.Watched{ .address = 0x2200_0040 };
    var made = watch_link.link(&watched);
    made.store(0x0200_0100, 0, 0x2200_0044, 4, 1);
    made.store(0x0200_0100, 0, 0x2200_003C, 2, 1);
    try std.testing.expectEqual(@as(usize, 0), watched.seen);
    try std.testing.expectEqual(@as(u32, 0), made.seen());
}

test "every store in a loop is counted, not only the first" {
    var watched = watchpoint.Watched{ .address = 0x2200_0040 };
    var made = watch_link.link(&watched);
    for (0..20) |n| made.store(0x0200_0100, 0, 0x2200_0040, 4, @intCast(n));
    try std.testing.expectEqual(@as(usize, 20), watched.seen);
    try std.testing.expectEqual(@as(u32, 20), made.seen());
}
