//! Covers src/interfaces/cli/src/interfaces/cli/report/json/timers.zig and json_watch.zig:
//! the `timers` object of `--report json`, parsed back with std.json.
const std = @import("std");
const ra8 = @import("ra8");
const cli_app = @import("cli_app");

const json_run = cli_app.report.json.run;
const Value = std.json.Value;
const Fixture = @import("../json_board.zig").Fixture;

fn timers(board: *ra8.board.board.Board, buf: *std.Io.Writer.Allocating) !std.json.Parsed(Value) {
    try json_run.document(&buf.writer, board, .{ .engine = "zig", .elapsed = 1 });
    return std.json.parseFromSlice(Value, std.testing.allocator, buf.written(), .{});
}

fn has(object: Value, keys: []const []const u8) !void {
    for (keys) |key| {
        if (object.object.get(key) == null) {
            std.debug.print("missing key {s}\n", .{key});
            return error.MissingKey;
        }
    }
}

test "a quiet board has every timers key and empty channel lists" {
    var fix: Fixture = undefined;
    try fix.open();
    defer fix.close();
    var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buf.deinit();
    const doc = try timers(&fix.board, &buf);
    defer doc.deinit();
    const top = doc.value.object.get("timers").?;
    try has(top, &.{ "ulpt", "agt", "gpt", "gpt_bank", "iwdt", "wdt0", "rtc" });
    for ([_][]const u8{ "ulpt", "agt", "gpt" }) |key| {
        try std.testing.expectEqual(@as(usize, 0), top.object.get(key).?.array.items.len);
    }
    try has(top.object.get("gpt_bank").?, &.{ "gtclk_programmed", "prohibited_running", "bits_acted", "stores_together", "absent_channels", "stray_stores" });
    try has(top.object.get("iwdt").?, &.{ "refreshes", "counter", "full_scale", "underflows", "running", "stopped_by_options", "option_word", "stopped_refreshes", "dropped_refreshes", "nmis", "bad_acks", "frozen_writes" });
    try has(top.object.get("wdt0").?, &.{ "refreshes", "refused_early", "counter", "reload", "underflows", "bad_acks", "dropped_locked" });
    try has(top.object.get("rtc").?, &.{ "year", "month", "day", "hour", "minute", "second", "seconds_counted", "alarm_matches", "alarm_events", "periodic_events", "refused_running", "resets", "refused_read_only", "count_source", "late_source_stores", "unsourced_resets", "hot_divisor_stores", "out_of_order_divisor" });
}

test "an AGT channel with underflows is listed with its index" {
    var fix: Fixture = undefined;
    try fix.open();
    defer fix.close();
    fix.board.interval.channels[1].underflows = 5;
    var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buf.deinit();
    const doc = try timers(&fix.board, &buf);
    defer doc.deinit();
    const list = doc.value.object.get("timers").?.object.get("agt").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), list.len);
    try std.testing.expectEqual(@as(i64, 1), list[0].object.get("index").?.integer);
    try std.testing.expectEqual(@as(i64, 5), list[0].object.get("underflows").?.integer);
    try has(list[0], &.{ "counter", "reload", "running", "matches_a", "matches_b", "masked_crossings", "forced_stops", "refused_running", "lost_cascade" });
}
