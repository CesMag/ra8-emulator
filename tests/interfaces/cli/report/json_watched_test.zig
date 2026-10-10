//! Covers src/interfaces/cli/report/json_watched.zig: the `watch` entry of
//! the `--report json` dumps object, written off a hand-fed watch log and
//! parsed back with std.json.
const std = @import("std");
const ra8 = @import("ra8");
const cli_app = @import("cli_app");

const json_watched = cli_app.report.json_run.json_dumps.json_watched;
const watchpoint = ra8.session.watchpoint;
const Value = std.json.Value;

fn render(found: ?*const watchpoint.Watched, buf: *std.Io.Writer.Allocating) !std.json.Parsed(Value) {
    var j = cli_app.report.json.Json(@TypeOf(&buf.writer)).init(&buf.writer);
    try j.open(null, '{');
    try json_watched.log(&j, null, "0x20000000", found);
    try j.close('}');
    return std.json.parseFromSlice(Value, std.testing.allocator, buf.written(), .{});
}

test "nothing watched writes null" {
    var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buf.deinit();
    const doc = try render(null, &buf);
    defer doc.deinit();
    try std.testing.expect(doc.value.object.get("watch").? == .null);
}

test "a quiet watch writes zero stores and empty lists" {
    const quiet = watchpoint.Watched{ .address = 0x2000_0000 };
    var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buf.deinit();
    const doc = try render(&quiet, &buf);
    defer doc.deinit();
    const watch = doc.value.object.get("watch").?.object;
    try std.testing.expectEqualStrings("0x20000000", watch.get("place").?.string);
    try std.testing.expectEqual(@as(i64, 0), watch.get("stores").?.integer);
    try std.testing.expectEqual(@as(usize, 0), watch.get("opening").?.array.items.len);
    try std.testing.expectEqual(@as(usize, 0), watch.get("closing").?.array.items.len);
    try std.testing.expectEqual(@as(i64, 0), watch.get("spacing").?.object.get("groups").?.integer);
    try std.testing.expectEqual(@as(usize, 0), watch.get("writers").?.object.get("sites").?.array.items.len);
}

test "stores land in the opening, the spacing and the writers" {
    var tick: u64 = 5;
    var log = watchpoint.Watched{ .address = 0x2000_0000, .now = &tick };
    log.record(0x100, 0x201, 0x2000_0002, 2, 7);
    tick = 9;
    log.record(0x100, 0x201, 0x2000_0000, 4, 7);
    var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buf.deinit();
    const doc = try render(&log, &buf);
    defer doc.deinit();
    const watch = doc.value.object.get("watch").?.object;
    try std.testing.expectEqual(@as(i64, 2), watch.get("stores").?.integer);
    const first = watch.get("opening").?.array.items[0].object;
    try std.testing.expectEqual(@as(i64, 2), first.get("byte").?.integer);
    try std.testing.expectEqual(@as(i64, 2), first.get("width").?.integer);
    try std.testing.expectEqual(@as(i64, 5), first.get("tick").?.integer);
    try std.testing.expect(first.get("caller").? == .null);
    const gaps = watch.get("spacing").?.object;
    try std.testing.expectEqual(@as(i64, 2), gaps.get("groups").?.integer);
    try std.testing.expectEqual(@as(i64, 4), gaps.get("mean").?.integer);
    const sites = watch.get("writers").?.object.get("sites").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), sites.len);
    try std.testing.expectEqual(@as(i64, 2), sites[0].object.get("stores").?.integer);
}
