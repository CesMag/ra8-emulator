//! Covers src/interfaces/cli/report/json_run.zig: the schema of the run and
//! cores sections of `--report json`, parsed back with std.json.
const std = @import("std");
const ra8 = @import("ra8");
const cli_app = @import("cli_app");

const json_run = cli_app.report.json_run;
const Value = std.json.Value;
const Fixture = @import("json_board.zig").Fixture;

/// The document for `board`, parsed. The caller frees both.
fn parsed(board: *ra8.board.board.Board, buf: *std.Io.Writer.Allocating) !std.json.Parsed(Value) {
    try json_run.document(&buf.writer, board, .{ .engine = "zig", .elapsed = 42, .bus_errors = .{ .raised = 2, .escalated = 1 } });
    try std.testing.expect(std.mem.endsWith(u8, buf.written(), "}\n"));
    try std.testing.expect(std.mem.count(u8, buf.written(), "\n") == 1);
    return std.json.parseFromSlice(Value, std.testing.allocator, buf.written(), .{});
}

fn int(object: Value, key: []const u8) !i64 {
    return switch (object.object.get(key) orelse return error.MissingKey) {
        .integer => |n| n,
        else => error.NotInteger,
    };
}

fn has(object: Value, key: []const u8, tag: std.meta.Tag(Value)) !void {
    const found = object.object.get(key) orelse return error.MissingKey;
    try std.testing.expectEqual(tag, std.meta.activeTag(found));
}

test "a quiet board has every run and cores key, and empty unit lists" {
    var fix: Fixture = undefined;
    try fix.open();
    defer fix.close();
    const board = &fix.board;
    var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buf.deinit();
    const doc = try parsed(board, &buf);
    defer doc.deinit();
    try std.testing.expectEqualStrings("ra8-report/1", doc.value.object.get("schema").?.string);
    const run = doc.value.object.get("run").?;
    try has(run, "part", .string);
    try std.testing.expectEqualStrings("zig", run.object.get("engine").?.string);
    try std.testing.expectEqual(@as(i64, 42), try int(run, "elapsed_instructions"));
    try std.testing.expectEqual(@as(i64, 0), try int(run, "elapsed_cycles"));
    for ([_][]const u8{ "reads", "writes", "unmodelled_registers" }) |key| _ = try int(run.object.get("bus").?, key);
    try std.testing.expectEqual(@as(i64, 2), try int(run.object.get("bus_faults").?, "raised"));
    try std.testing.expectEqual(@as(i64, 1), try int(run.object.get("bus_faults").?, "escalated"));
    const cores = doc.value.object.get("cores").?;
    const cpu1 = cores.object.get("cpu1").?;
    for ([_][]const u8{ "activated", "running", "mapped" }) |key| try has(cpu1, key, .bool);
    for ([_][]const u8{ "vector_table", "actcsr", "refused_stores" }) |key| _ = try int(cpu1, key);
    const box = cores.object.get("ipc").?;
    _ = try int(box, "wakes");
    _ = try int(box, "undelivered");
    for ([_][]const u8{ "channels", "semaphores", "doorbells" }) |key| {
        try std.testing.expectEqual(@as(usize, 0), box.object.get(key).?.array.items.len);
    }
}

test "busy IPC units are listed with their index and counts" {
    var fix: Fixture = undefined;
    try fix.open();
    defer fix.close();
    const board = &fix.board;
    board.second_core.act = true;
    board.second_core.initvtor = 0x0200_0000;
    board.mailbox.channels[2].sends = 3;
    board.mailbox.channels[2].lost = 1;
    board.mailbox.locks.semaphores[5].takes = 4;
    board.mailbox.locks.semaphores[5].locked = true;
    board.mailbox.locks.doorbells[1].sends = 2;
    var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buf.deinit();
    const doc = try parsed(board, &buf);
    defer doc.deinit();
    const cores = doc.value.object.get("cores").?;
    try std.testing.expect(cores.object.get("cpu1").?.object.get("activated").?.bool);
    try std.testing.expectEqual(@as(i64, 0x0200_0000), try int(cores.object.get("cpu1").?, "vector_table"));
    const box = cores.object.get("ipc").?;
    const channel = box.object.get("channels").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), channel.len);
    try std.testing.expectEqual(@as(i64, 2), try int(channel[0], "index"));
    try std.testing.expectEqual(@as(i64, 3), try int(channel[0], "sends"));
    try std.testing.expectEqual(@as(i64, 1), try int(channel[0], "lost"));
    for ([_][]const u8{ "pushed", "taken", "status", "starved", "narrow_reads", "narrow_writes" }) |key| _ = try int(channel[0], key);
    const sem = box.object.get("semaphores").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), sem.len);
    try std.testing.expectEqual(@as(i64, 5), try int(sem[0], "index"));
    try std.testing.expect(sem[0].object.get("held").?.bool);
    const bell = box.object.get("doorbells").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), bell.len);
    try std.testing.expectEqual(@as(i64, 1), try int(bell[0], "index"));
    try std.testing.expectEqual(@as(i64, 2), try int(bell[0], "sent"));
}
