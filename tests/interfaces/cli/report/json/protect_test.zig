//! Covers src/interfaces/cli/src/interfaces/cli/report/json/protect.zig: the `protection`
//! object of `--report json`, parsed back with std.json.
const std = @import("std");
const ra8 = @import("ra8");
const cli_app = @import("cli_app");

const json_run = cli_app.report.json.run;
const Value = std.json.Value;
const Fixture = @import("../json_board.zig").Fixture;

fn protection(board: *ra8.board.board.Board, buf: *std.Io.Writer.Allocating) !std.json.Parsed(Value) {
    try json_run.document(&buf.writer, board, .{ .engine = "zig", .elapsed = 1 });
    return std.json.parseFromSlice(Value, std.testing.allocator, buf.written(), .{});
}

fn int(object: Value, key: []const u8) !i64 {
    return switch (object.object.get(key) orelse return error.MissingKey) {
        .integer => |n| n,
        else => error.NotInteger,
    };
}

fn flag(object: Value, key: []const u8) !bool {
    return switch (object.object.get(key) orelse return error.MissingKey) {
        .bool => |b| b,
        else => error.NotBool,
    };
}

test "a quiet board has every protection key, all zero or false" {
    var fix: Fixture = undefined;
    try fix.open();
    defer fix.close();
    const board = &fix.board;
    var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buf.deinit();
    const doc = try protection(board, &buf);
    defer doc.deinit();
    const top = doc.value.object.get("protection").?;
    const mpu = top.object.get("mpu").?;
    for ([_][]const u8{ "enabled", "privileged_default", "stood_down" }) |key| try std.testing.expect(!try flag(mpu, key));
    for ([_][]const u8{ "programmed_regions", "read_only_regions", "refused_stores", "refused_loads", "refused_fetches", "outside_every_region", "unprivileged", "memmanage", "escalated", "unhandled" }) |key| {
        try std.testing.expectEqual(@as(i64, 0), try int(mpu, key));
    }
    try std.testing.expect(try int(mpu, "regions") > 0);
    const sau = top.object.get("sau").?;
    for ([_][]const u8{ "enabled", "outside_is_non_secure" }) |key| _ = try flag(sau, key);
    for ([_][]const u8{ "programmed_regions", "regions", "non_secure_callable", "refused_type_stores" }) |key| _ = try int(sau, key);
    const ipc = top.object.get("ipc_attribution").?;
    for ([_][]const u8{ "ipcsar", "ipcpar", "non_secure_channels", "refused_stores" }) |key| _ = try int(ipc, key);
    const chip = top.object.get("cpscu_attribution").?;
    for ([_][]const u8{ "bussara", "bussarb", "bussarc", "mmpusara", "mmpusarb", "cpusar", "refused_stores", "reserved_stores" }) |key| _ = try int(chip, key);
}

test "MPU refusals split into stores, loads and fetches as the text does" {
    var fix: Fixture = undefined;
    try fix.open();
    defer fix.close();
    const board = &fix.board;
    board.guard.latch.violations = 7;
    board.guard.latch.loads = 2;
    board.guard.latch.fetches = 1;
    board.guard.latch.faults = 6;
    board.guard.latch.stood_down = true;
    board.mailbox.attrib.locked_writes = 3;
    var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buf.deinit();
    const doc = try protection(board, &buf);
    defer doc.deinit();
    const top = doc.value.object.get("protection").?;
    const mpu = top.object.get("mpu").?;
    try std.testing.expectEqual(@as(i64, 4), try int(mpu, "refused_stores"));
    try std.testing.expectEqual(@as(i64, 2), try int(mpu, "refused_loads"));
    try std.testing.expectEqual(@as(i64, 1), try int(mpu, "refused_fetches"));
    try std.testing.expectEqual(@as(i64, 6), try int(mpu, "memmanage"));
    try std.testing.expect(try flag(mpu, "stood_down"));
    try std.testing.expectEqual(@as(i64, 3), try int(top.object.get("ipc_attribution").?, "refused_stores"));
}
