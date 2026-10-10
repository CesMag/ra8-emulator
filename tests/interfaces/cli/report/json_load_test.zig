//! Covers src/interfaces/cli/report/json_load.zig: the `cpu_load` object of
//! `--report json`, built from a tracer fed a known run and parsed back
//! with std.json.
const std = @import("std");
const ra8 = @import("ra8");
const cli_app = @import("cli_app");

const json_run = cli_app.report.json_run;
const json_load = json_run.json_load;
const rtos_hook = ra8.session.step_hook.rtos_hook;
const Value = std.json.Value;
const Fixture = @import("json_board.zig").Fixture;

const thread_a: u32 = 0x2200_10F0;

/// Thread 0x2200_10F0 from 10 to 100, SysTick inside it for 10, then idle
/// to 200 after a switch to nothing: the load the text table prints too.
fn run(clock: *u64) rtos_hook.Tracer {
    var tracer = rtos_hook.Tracer{ .address = 0x2200_1ABC, .now = clock };
    clock.* = 10;
    tracer.onStore(0x2200_1ABC, 4, thread_a);
    clock.* = 40;
    tracer.trace.exception(0, clock.*, .enter, 15);
    clock.* = 50;
    tracer.trace.exception(0, clock.*, .leave, 15);
    clock.* = 100;
    return tracer;
}

fn render(board: *ra8.board.board.Board, load: ?*const json_load.Load, buf: *std.Io.Writer.Allocating) !std.json.Parsed(Value) {
    try json_run.document(&buf.writer, board, .{ .engine = "zig", .elapsed = 1, .load = load });
    return std.json.parseFromSlice(Value, std.testing.allocator, buf.written(), .{});
}

test "no --cpu-load writes null" {
    var fix: Fixture = undefined;
    try fix.open();
    defer fix.close();
    var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buf.deinit();
    const doc = try render(&fix.board, null, &buf);
    defer doc.deinit();
    try std.testing.expect(doc.value.object.get("cpu_load").? == .null);
}

test "a core with nothing traced is null inside the object" {
    var fix: Fixture = undefined;
    try fix.open();
    defer fix.close();
    var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buf.deinit();
    const doc = try render(&fix.board, &.{}, &buf);
    defer doc.deinit();
    const load = doc.value.object.get("cpu_load").?.object;
    try std.testing.expect(load.get("cpu0").? == .null);
    try std.testing.expect(load.get("cpu1").? == .null);
}

test "the known run's owners, instructions and permille" {
    var fix: Fixture = undefined;
    try fix.open();
    defer fix.close();
    var clock: u64 = 0;
    const tracer = run(&clock);
    const load = json_load.Load{ .cpu0 = .{ .tracer = &tracer, .memory = .{ .guest = fix.memory() } } };
    var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buf.deinit();
    const doc = try render(&fix.board, &load, &buf);
    defer doc.deinit();
    const cpu0 = doc.value.object.get("cpu_load").?.object.get("cpu0").?.object;
    try std.testing.expectEqual(@as(i64, 100), cpu0.get("instructions").?.integer);
    const owners = cpu0.get("owners").?.array.items;
    try std.testing.expectEqual(@as(usize, 3), owners.len);
    try expectOwner(owners[0], "before", null, 10, 100);
    try expectOwner(owners[1], "thread", thread_a, 80, 800);
    try expectOwner(owners[2], "exception", 15, 10, 100);
    try std.testing.expectEqualStrings("SysTick", owners[2].object.get("name").?.string);
    try std.testing.expect(owners[1].object.get("name").? == .null);
    const other = cpu0.get("other").?.object;
    try std.testing.expectEqual(@as(i64, 0), other.get("instructions").?.integer);
    try std.testing.expectEqual(@as(i64, 0), other.get("permille").?.integer);
}

test "shares on a core add up to exactly 1000" {
    var fix: Fixture = undefined;
    try fix.open();
    defer fix.close();
    var clock: u64 = 0;
    var tracer = rtos_hook.Tracer{ .address = 0x2200_1ABC, .now = &clock };
    clock = 1;
    tracer.onStore(0x2200_1ABC, 4, thread_a);
    clock = 2;
    tracer.onStore(0x2200_1ABC, 4, thread_a + 0x100);
    clock = 3;
    const load = json_load.Load{ .cpu0 = .{ .tracer = &tracer, .memory = .{ .guest = fix.memory() } } };
    var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buf.deinit();
    const doc = try render(&fix.board, &load, &buf);
    defer doc.deinit();
    const owners = doc.value.object.get("cpu_load").?.object.get("cpu0").?.object.get("owners").?.array.items;
    var sum: i64 = 0;
    for (owners) |one| sum += one.object.get("permille").?.integer;
    try std.testing.expectEqual(@as(i64, 1000), sum);
}

fn expectOwner(value: Value, kind: []const u8, id: ?i64, instructions: i64, permille: i64) !void {
    const one = value.object;
    try std.testing.expectEqualStrings(kind, one.get("kind").?.string);
    if (id) |want| {
        try std.testing.expectEqual(want, one.get("id").?.integer);
    } else try std.testing.expect(one.get("id").? == .null);
    try std.testing.expectEqual(instructions, one.get("instructions").?.integer);
    try std.testing.expectEqual(permille, one.get("permille").?.integer);
}

test "ctl cpu-load emits the same per-core object as the report field" {
    var fix: Fixture = undefined;
    try fix.open();
    defer fix.close();
    var clock: u64 = 0;
    const tracer = run(&clock);
    const load = json_load.Load{ .cpu0 = .{ .tracer = &tracer, .memory = .{ .guest = fix.memory() } } };
    var report_buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer report_buf.deinit();
    const report_doc = try render(&fix.board, &load, &report_buf);
    defer report_doc.deinit();
    var ctl_buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer ctl_buf.deinit();
    try json_load.document(&ctl_buf.writer, &load);
    const ctl_doc = try std.json.parseFromSlice(Value, std.testing.allocator, ctl_buf.written(), .{});
    defer ctl_doc.deinit();

    const report_load = report_doc.value.object.get("cpu_load").?.object;
    try std.testing.expectEqual(@as(usize, 2), ctl_doc.value.object.count());
    try std.testing.expectEqual(@as(i64, 100), ctl_doc.value.object.get("cpu0").?.object.get("instructions").?.integer);
    try std.testing.expect(ctl_doc.value.object.get("cpu1").? == .null);
    try expectOwnerArraysEqual(
        report_load.get("cpu0").?.object.get("owners").?.array.items,
        ctl_doc.value.object.get("cpu0").?.object.get("owners").?.array.items,
    );
    try std.testing.expectEqual(
        report_load.get("cpu0").?.object.get("other").?.object.get("instructions").?.integer,
        ctl_doc.value.object.get("cpu0").?.object.get("other").?.object.get("instructions").?.integer,
    );
}

fn expectOwnerArraysEqual(expected: []const Value, actual: []const Value) !void {
    try std.testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |want, got| {
        const a = want.object;
        const b = got.object;
        try std.testing.expectEqualStrings(a.get("kind").?.string, b.get("kind").?.string);
        try expectNullableValue(a.get("id").?, b.get("id").?);
        try expectNullableValue(a.get("name").?, b.get("name").?);
        try std.testing.expectEqual(a.get("instructions").?.integer, b.get("instructions").?.integer);
        try std.testing.expectEqual(a.get("permille").?.integer, b.get("permille").?.integer);
    }
}

fn expectNullableValue(expected: Value, actual: Value) !void {
    if (expected == .null) return std.testing.expect(actual == .null);
    if (expected == .integer) return std.testing.expectEqual(expected.integer, actual.integer);
    return std.testing.expectEqualStrings(expected.string, actual.string);
}
