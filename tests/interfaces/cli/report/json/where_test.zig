//! Covers src/interfaces/cli/src/interfaces/cli/report/json/where.zig: the `steps`,
//! `hotspots`, `functions` and `profile` objects of `--report json`,
//! parsed back with std.json.
const std = @import("std");
const ra8 = @import("ra8");
const cli_app = @import("cli_app");

const json_run = cli_app.report.json.run;
const where = json_run.json_where;
const Value = std.json.Value;
const Fixture = @import("../json_board.zig").Fixture;

fn render(board: *ra8.board.board.Board, of: where.Where, buf: *std.Io.Writer.Allocating) !std.json.Parsed(Value) {
    try json_run.document(&buf.writer, board, .{ .engine = "zig", .elapsed = 1, .where = of });
    return std.json.parseFromSlice(Value, std.testing.allocator, buf.written(), .{});
}

test "a run that collected nothing writes null for every table" {
    var fix: Fixture = undefined;
    try fix.open();
    defer fix.close();
    var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buf.deinit();
    const doc = try render(&fix.board, .{}, &buf);
    defer doc.deinit();
    for ([_][]const u8{ "steps", "hotspots", "functions", "profile" }) |key| {
        try std.testing.expect(doc.value.object.get(key).? == .null);
    }
}

test "steps and a sampled table carry their counts" {
    var fix: Fixture = undefined;
    try fix.open();
    defer fix.close();
    var pcs: where.Pcs = .{};
    pcs.sample(0x1000);
    pcs.sample(0x1000);
    pcs.sample(0x2000);
    var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buf.deinit();
    const doc = try render(&fix.board, .{
        .steps = .{ .loops = .{ .stepped = 3 }, .selects = .{}, .worlds = .{} },
        .pcs = &pcs,
    }, &buf);
    defer doc.deinit();
    const steps = doc.value.object.get("steps").?;
    try std.testing.expectEqual(@as(i64, 3), steps.object.get("loops_stepped").?.integer);
    const tz = steps.object.get("trustzone").?;
    try std.testing.expect(tz.object.get("armed_at").? == .null);
    try std.testing.expect(!tz.object.get("entered").?.bool);
    const hot = doc.value.object.get("hotspots").?;
    try std.testing.expectEqual(@as(i64, 3), hot.object.get("samples").?.integer);
    const sites = hot.object.get("sites").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), sites.len);
    try std.testing.expectEqual(@as(i64, 0x1000), sites[0].object.get("pc").?.integer);
    try std.testing.expectEqual(@as(i64, 66), sites[0].object.get("share_percent").?.integer);
    try std.testing.expect(sites[0].object.get("symbol").? == .null);
    try std.testing.expect(doc.value.object.get("functions").? == .null);
}
