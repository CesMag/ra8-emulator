//! Tests for src/components/esp32c6_hosted/landing.zig: a call is counted
//! for the record, held traffic lands the recorded frames and touches
//! nothing else, a recorded frame the queue cannot take is reported, and
//! the frames a call put on the queue are told to the record in order.
const std = @import("std");
const ra8 = @import("ra8");
const hosted = ra8.components.esp_hosted;
const frame = hosted.frame;
const hold = hosted.hold;
const landing = hosted.landing;
const Queue = hosted.queue.Queue;

const Record = struct {
    entered: u32 = 0,
    told: u32 = 0,
    due: u32 = 2,
    failed: bool = false,
    is_held: bool = true,

    fn enter(context: *anyopaque, _: hold.Site) void {
        const self: *Record = @ptrCast(@alignCast(context));
        self.entered += 1;
    }
    fn landed(context: *anyopaque, _: hold.Site, _: hold.Kind, bytes: []const u8) void {
        const self: *Record = @ptrCast(@alignCast(context));
        self.told += @intCast(bytes.len);
    }
    fn next(context: *anyopaque, _: hold.Site, out: []u8) ?hold.Due {
        const self: *Record = @ptrCast(@alignCast(context));
        if (self.due == 0) return null;
        self.due -= 1;
        @memset(out[0..3], 0xAB);
        return .{ .kind = .bytes, .len = 3 };
    }
    fn fail(context: *anyopaque) void {
        const self: *Record = @ptrCast(@alignCast(context));
        self.failed = true;
    }
    fn heldNow(context: *anyopaque) bool {
        const self: *Record = @ptrCast(@alignCast(context));
        return self.is_held;
    }
    fn port(self: *Record) hold.Landing {
        return .{ .context = self, .enterFn = enter, .landedFn = landed, .dueFn = next, .failFn = fail };
    }
    fn hold_(self: *Record) hold.Hold {
        return .{ .context = self, .heldFn = heldNow };
    }
};

test "held traffic lands the recorded frames on the queue and reports the call" {
    var record: Record = .{};
    var q: Queue = .{};
    try std.testing.expect(landing.enter(record.port(), record.hold_(), &q, .poll));
    try std.testing.expectEqual(@as(u32, 1), record.entered);
    try std.testing.expectEqual(@as(usize, 2), q.len);
    var out: [frame.frame_size]u8 = undefined;
    try std.testing.expect(q.pop(&out));
    try std.testing.expectEqualSlices(u8, &.{ 0xAB, 0xAB, 0xAB }, (try frame.parse(&out)).payload);
}

test "traffic that is not held lands nothing and a missing record is the same as none" {
    var record: Record = .{ .is_held = false };
    var q: Queue = .{};
    try std.testing.expect(!landing.enter(record.port(), record.hold_(), &q, .forward));
    try std.testing.expect(q.isEmpty());
    try std.testing.expect(!landing.enter(null, null, &q, .forward));
    record.is_held = true;
    try std.testing.expect(landing.enter(null, record.hold_(), &q, .forward));
    try std.testing.expect(q.isEmpty());
}

test "a frame the full queue cannot take is reported" {
    var record: Record = .{ .due = 10 };
    var q: Queue = .{};
    try std.testing.expect(landing.enter(record.port(), record.hold_(), &q, .poll));
    try std.testing.expect(record.failed);
    try std.testing.expectEqual(@as(usize, hosted.queue.capacity), q.len);
}

test "the frames a call put on the queue are told to the record from the mark" {
    var record: Record = .{ .is_held = false };
    var q: Queue = .{};
    var item: [frame.frame_size]u8 = undefined;
    try frame.build(&item, .{ .interface = .sta, .if_num = 0 }, "abcd");
    try std.testing.expect(q.push(&item));
    const mark = q.len;
    try frame.build(&item, .{ .interface = .sta, .if_num = 0 }, "xy");
    try std.testing.expect(q.push(&item));
    try std.testing.expectEqual(@as(usize, 2), landing.report(record.port(), &q, mark, .poll, .answer));
    try std.testing.expectEqual(@as(u32, 2), record.told);
}
