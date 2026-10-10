//! RA8EMU-661: virtual time and the event queue saved mid-run and loaded
//! into a fresh Time pop the same events in the same order.
const std = @import("std");
const ra8 = @import("ra8");
const file = ra8.snapshot.file;
const snap = ra8.chip.snapshot.time;
const clocks = ra8.chip.periph.clocks;

fn running() !clocks.Time {
    var time: clocks.Time = .{};
    time.base.setRate(200_000_000);
    time.base.advance(1_000);
    try time.queue.schedule(9_000, 3);
    try time.queue.schedule(7_000, 1);
    try time.queue.schedule(9_000, 2);
    try time.queue.schedule(30_000, 4);
    _ = time.queue.popDue(time.base.now() + 7_000);
    return time;
}

fn snapshot(time: *const clocks.Time, list: *std.Io.Writer.Allocating) !void {
    try file.writeHeader(&list.writer);
    try snap.save(time, &list.writer);
}

fn drain(time: *clocks.Time, out: *[8]u16) usize {
    var n: usize = 0;
    while (time.queue.popDue(std.math.maxInt(u64))) |event| : (n += 1) out[n] = event.id;
    return n;
}

test "time and pending events restore and fire in the same order" {
    var first = try running();
    var list = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer list.deinit();
    try snapshot(&first, &list);
    var second: clocks.Time = .{};
    try snap.load(&second, list.written());
    try std.testing.expectEqual(first.base.now(), second.base.now());
    try std.testing.expectEqualDeep(first.base, second.base);
    // New events after the restore get the same sequence numbers too.
    try first.queue.schedule(9_000, 5);
    try second.queue.schedule(9_000, 5);
    var want: [8]u16 = undefined;
    var got: [8]u16 = undefined;
    const n = drain(&first, &want);
    try std.testing.expectEqual(n, drain(&second, &got));
    try std.testing.expectEqualSlices(u16, &.{ 3, 2, 5, 4 }, want[0..n]);
    try std.testing.expectEqualSlices(u16, want[0..n], got[0..n]);
}

test "a count past capacity or an unsorted queue is refused and nothing changes" {
    var first = try running();
    var list = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer list.deinit();
    try snapshot(&first, &list);
    var target: clocks.Time = .{};
    target.base.advance(5);
    // The count byte sits after the header, the time base and next_seq.
    const count_at = file.magic.len + 4 + 12 + 4 * 8 + 4;
    try std.testing.expectEqual(@as(u8, 3), list.written()[count_at]);
    list.written()[count_at] = 200;
    try std.testing.expectError(error.BadValue, snap.load(&target, list.written()));
    list.written()[count_at] = 3;
    // Swap the first event's time with the last's.
    const first_event = count_at + 1;
    const last_event = first_event + 2 * 14;
    var a: [8]u8 = list.written()[first_event..][0..8].*;
    @memcpy(list.written()[first_event..][0..8], list.written()[last_event..][0..8]);
    @memcpy(list.written()[last_event..][0..8], &a);
    try std.testing.expectError(error.BadValue, snap.load(&target, list.written()));
    try std.testing.expectEqual(@as(u64, 5), target.base.cycles);
    try std.testing.expectEqual(@as(usize, 0), target.queue.count);
}

test "a file without a time section is Missing" {
    var list = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer list.deinit();
    try file.writeHeader(&list.writer);
    var target: clocks.Time = .{};
    try std.testing.expectError(error.Missing, snap.load(&target, list.written()));
}
