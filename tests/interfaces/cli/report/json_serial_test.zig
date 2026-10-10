//! Covers src/interfaces/cli/report/json_serial.zig, json_storage.zig and
//! json_riic.zig: the `serial`, `storage` and `riic` parts of
//! `--report json`, parsed back with std.json.
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

test "a quiet board has every serial, storage and riic key" {
    var fix: Fixture = undefined;
    try fix.open();
    defer fix.close();
    var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buf.deinit();
    const doc = try render(&fix.board, &buf);
    defer doc.deinit();
    const serial = doc.value.object.get("serial").?;
    try has(serial, &.{ "sci", "console", "spi", "rtt" });
    try std.testing.expectEqual(@as(usize, 0), serial.object.get("sci").?.array.items.len);
    try std.testing.expectEqual(@as(usize, 0), serial.object.get("spi").?.array.items.len);
    try has(serial.object.get("console").?, &.{ "lines", "last" });
    try has(serial.object.get("rtt").?, &.{ "control_block", "drained", "lines", "last", "pending", "cut_lines", "refused_off_ram", "forgotten" });
    const storage = doc.value.object.get("storage").?;
    try has(storage, &.{ "ospi_early_releases", "dotf", "xspi_flash", "sdhi", "sd_spi" });
    try std.testing.expectEqual(@as(usize, 0), storage.object.get("dotf").?.array.items.len);
    try has(storage.object.get("xspi_flash").?, &.{ "reads", "programs", "erases", "sectors_held", "refused_unarmed", "refused_oversized", "refused_out_of_part", "wrapped_programs", "refused_ints_stores", "lost_programs", "stalled" });
    try has(storage.object.get("sdhi").?, &.{ "reads", "writes", "blocks_held", "bus_width", "refused_unselected", "refused_in_reset", "refused_response_stores", "starved_buffer", "refused_narrow", "refused_past_end", "ended_on_refusal" });
    try has(storage.object.get("sd_spi").?, &.{ "volume", "commands", "reads", "writes", "blocks_held", "refused_uninit", "refused_past_end", "refused_crc", "refused_erase_sequence", "erased" });
    try std.testing.expectEqual(@as(usize, 0), doc.value.object.get("riic").?.array.items.len);
}

test "a SCI channel that moved bytes is listed with its index" {
    var fix: Fixture = undefined;
    try fix.open();
    defer fix.close();
    fix.board.serial.channels[3].transmitted = 12;
    var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buf.deinit();
    const doc = try render(&fix.board, &buf);
    defer doc.deinit();
    const list = doc.value.object.get("serial").?.object.get("sci").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), list.len);
    try std.testing.expectEqual(@as(i64, 3), list[0].object.get("index").?.integer);
    try std.testing.expectEqual(@as(i64, 12), list[0].object.get("transmitted").?.integer);
    try has(list[0], &.{ "received", "rx_dropped", "unsent_te_clear", "refused_status_stores", "overruns", "overrun_standing", "refused_unnamed_reads", "refused_unnamed_stores", "idle_frames", "lin" });
    try has(list[0].object.get("lin").?, &.{ "breaks", "break_length", "refused_unenabled", "refused_status_stores" });
}

test "a RIIC channel with transfers carries its target half" {
    var fix: Fixture = undefined;
    try fix.open();
    defer fix.close();
    fix.board.wire.controller.channels[1].transfers = 4;
    var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buf.deinit();
    const doc = try render(&fix.board, &buf);
    defer doc.deinit();
    const list = doc.value.object.get("riic").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), list.len);
    try std.testing.expectEqual(@as(i64, 1), list[0].object.get("index").?.integer);
    try std.testing.expectEqual(@as(i64, 4), list[0].object.get("transfers").?.integer);
    try has(list[0].object.get("target").?, &.{ "own_address", "cycles", "mismatched", "nacked_reads", "refused_unaddressed" });
}
