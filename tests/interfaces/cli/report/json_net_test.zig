//! Covers src/interfaces/cli/report/json_net.zig and json_i2c.zig: the
//! `network` object of `--report json`, parsed back with std.json.
const std = @import("std");
const ra8 = @import("ra8");
const cli_app = @import("cli_app");

const json_run = cli_app.report.json_run;
const Value = std.json.Value;
const Fixture = @import("json_board.zig").Fixture;

fn render(board: *ra8.board.board.Board, buf: *std.Io.Writer.Allocating) !std.json.Parsed(Value) {
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

test "a quiet board has every network key and empty lists" {
    var fix: Fixture = undefined;
    try fix.open();
    defer fix.close();
    var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buf.deinit();
    const doc = try render(&fix.board, &buf);
    defer doc.deinit();
    const net = doc.value.object.get("network").?;
    try has(net, &.{ "can", "can_wakes", "gptp", "modem", "i2c_parts" });
    try std.testing.expectEqual(@as(usize, 0), net.object.get("can").?.array.items.len);
    const gptp = net.object.get("gptp").?;
    try has(gptp, &.{ "timers", "unknown_unit_bits", "denormal_offsets", "refused_monitor_stores", "refused_ptpipv_stores" });
    try std.testing.expectEqual(@as(usize, 0), gptp.object.get("timers").?.array.items.len);
    try has(net.object.get("modem").?, &.{ "answered", "cme_errors", "refused_overlong", "unterminated", "sci_channel", "lost_reply_bytes" });
    const parts = net.object.get("i2c_parts").?;
    try has(parts, &.{ "click_fitted", "expander", "camera", "touch", "i3c", "imu", "gauge" });
    try has(parts.object.get("i3c").?.object.get("target").?, &.{ "own_address", "cycles", "mismatched", "refused_unprompted", "starved_drains", "refused_reserved" });
    try has(parts.object.get("imu").?, &.{ "bursts", "writes", "accel_running", "gyro_running", "refused_unstarted", "refused_read_only", "refused_bad_pointer", "past_end" });
    try has(parts.object.get("gauge").?, &.{ "soc_pct", "charging", "reads", "writes", "refused_read_only", "refused_misaligned", "refused_unmapped", "torn_words", "resets" });
}

test "a CAN controller that sent frames is listed with its index" {
    var fix: Fixture = undefined;
    try fix.open();
    defer fix.close();
    fix.board.can.units[0].sent = 3;
    var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buf.deinit();
    const doc = try render(&fix.board, &buf);
    defer doc.deinit();
    const list = doc.value.object.get("network").?.object.get("can").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), list.len);
    try std.testing.expectEqual(@as(i64, 0), list[0].object.get("index").?.integer);
    try std.testing.expectEqual(@as(i64, 3), list[0].object.get("transmitted").?.integer);
    try has(list[0], &.{ "received", "waiting", "refused_out_of_operation", "filtered", "lost_no_stage", "overrun_standing", "overrun_acks", "refused_rfsts_stores", "dropped_fifo_off", "refused_rfe_stores", "empty_pops", "dropped_tmtrf_standing", "ignored_mode_writes", "refused_status_stores", "refused_erfl_stores", "error_flags" });
}
