//! Covers src/interfaces/cli/report/json/sd.zig: the `sd` entry of the
//! `--report json` dumps object, written off the fixture board's card and
//! parsed back with std.json.
const std = @import("std");
const ra8 = @import("ra8");
const cli_app = @import("cli_app");

const json_sd = cli_app.report.json.run.json_dumps.json_sd;
const geometry = json_sd.geometry;
const Value = std.json.Value;
const Fixture = @import("../json_board.zig").Fixture;

fn render(board: *ra8.board.board.Board, asked: ?u32, buf: *std.Io.Writer.Allocating) !std.json.Parsed(Value) {
    var j = cli_app.report.json.Json(@TypeOf(&buf.writer)).init(&buf.writer);
    try j.open(null, '{');
    try json_sd.block(&j, board, asked);
    try j.close('}');
    return std.json.parseFromSlice(Value, std.testing.allocator, buf.written(), .{});
}

test "no --dump-sd writes null" {
    var fix: Fixture = undefined;
    try fix.open();
    defer fix.close();
    var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buf.deinit();
    const doc = try render(&fix.board, null, &buf);
    defer doc.deinit();
    try std.testing.expect(doc.value.object.get("sd").? == .null);
}

test "a block past the card is off the card with no rows" {
    var fix: Fixture = undefined;
    try fix.open();
    defer fix.close();
    var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buf.deinit();
    const doc = try render(&fix.board, 0xFFFF_FFF0, &buf);
    defer doc.deinit();
    const sd = doc.value.object.get("sd").?.object;
    try std.testing.expectEqual(@as(i64, 0xFFFF_FFF0), sd.get("block").?.integer);
    try std.testing.expect(!sd.get("on_card").?.bool);
    try std.testing.expectEqual(@as(usize, 0), sd.get("rows").?.array.items.len);
    try std.testing.expectEqual(@as(i64, 0), sd.get("zero_rows").?.integer);
}

test "a written block keeps its non-zero rows and counts the rest" {
    var fix: Fixture = undefined;
    try fix.open();
    defer fix.close();
    const bytes = try std.testing.allocator.alloc(u8, geometry.block_bytes * geometry.csize_unit);
    defer std.testing.allocator.free(bytes);
    @memset(bytes, 0);
    bytes[geometry.block_bytes + 17] = 0xAB;
    try fix.board.sd.img.loadBytes(bytes);
    var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buf.deinit();
    const doc = try render(&fix.board, 1, &buf);
    defer doc.deinit();
    const sd = doc.value.object.get("sd").?.object;
    try std.testing.expect(sd.get("on_card").?.bool);
    const rows = sd.get("rows").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), rows.len);
    try std.testing.expectEqual(@as(i64, 16), rows[0].object.get("offset").?.integer);
    try std.testing.expectEqualStrings("00ab0000000000000000000000000000", rows[0].object.get("hex").?.string);
    try std.testing.expectEqual(@as(i64, geometry.block_bytes / 16 - 1), sd.get("zero_rows").?.integer);
}
