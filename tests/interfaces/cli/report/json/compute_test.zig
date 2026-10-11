//! Covers src/interfaces/cli/src/interfaces/cli/report/json/compute.zig: the `compute` object
//! of `--report json`, parsed back with std.json.
const std = @import("std");
const ra8 = @import("ra8");
const cli_app = @import("cli_app");

const json_run = cli_app.report.json.run;
const Value = std.json.Value;
const Fixture = @import("../json_board.zig").Fixture;

fn render(board: *ra8.board.board.Board, buf: *std.Io.Writer.Allocating) !std.json.Parsed(Value) {
    try json_run.document(&buf.writer, board, .{ .engine = "zig", .elapsed = 1 });
    return std.json.parseFromSlice(Value, std.testing.allocator, buf.written(), .{});
}

test "a quiet board has every compute key and an untouched NPU" {
    var fix: Fixture = undefined;
    try fix.open();
    defer fix.close();
    var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buf.deinit();
    const doc = try render(&fix.board, &buf);
    defer doc.deinit();
    const compute = doc.value.object.get("compute").?;
    const keys = [_][]const u8{ "touched", "reads", "writes", "jobs", "moved", "last_op", "last_bytes", "last_check", "refused_unknown_ops", "refused_malformed", "refused_unmapped_region", "faulted_unreachable", "in_place", "short_jobs", "short_bytes", "refused_id_status_stores", "vela" };
    for (keys) |key| try std.testing.expect(compute.object.get(key) != null);
    try std.testing.expect(!compute.object.get("touched").?.bool);
    try std.testing.expect(compute.object.get("last_op").? == .null);
    const vela = compute.object.get("vela").?;
    for ([_][]const u8{ "kicks", "jobs", "moved", "refused_unmodelled", "refused_malformed", "faulted" }) |key| {
        try std.testing.expect(vela.object.get(key) != null);
    }
}

test "NPU job counts carry through" {
    var fix: Fixture = undefined;
    try fix.open();
    defer fix.close();
    fix.board.npu.jobs = 2;
    fix.board.npu.moved = 64;
    var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buf.deinit();
    const doc = try render(&fix.board, &buf);
    defer doc.deinit();
    const compute = doc.value.object.get("compute").?;
    try std.testing.expectEqual(@as(i64, 2), compute.object.get("jobs").?.integer);
    try std.testing.expectEqual(@as(i64, 64), compute.object.get("moved").?.integer);
}
