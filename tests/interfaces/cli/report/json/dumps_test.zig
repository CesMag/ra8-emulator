//! Covers src/interfaces/cli/report/json_dumps.zig: the `dumps` object of
//! `--report json`, read off the Zig core's store and registers and parsed
//! back with std.json.
const std = @import("std");
const ra8 = @import("ra8");
const cli_app = @import("cli_app");

const json_run = cli_app.report.json.run;
const json_dumps = json_run.json_dumps;
const Regs = ra8.chip.core.cpu.regs.Regs;
const Options = cli_app.cli.Options;
const Value = std.json.Value;
const Fixture = @import("../json_board.zig").Fixture;

const base: u32 = ra8.chip.core.memmap.sram_base;

fn render(board: *ra8.board.board.Board, dumps: ?*const json_dumps.Dumps, buf: *std.Io.Writer.Allocating) !std.json.Parsed(Value) {
    try json_run.document(&buf.writer, board, .{ .engine = "zig", .elapsed = 1, .dumps = dumps });
    return std.json.parseFromSlice(Value, std.testing.allocator, buf.written(), .{});
}

test "a run with no core handed over writes null" {
    var fix: Fixture = undefined;
    try fix.open();
    defer fix.close();
    var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buf.deinit();
    const doc = try render(&fix.board, null, &buf);
    defer doc.deinit();
    try std.testing.expect(doc.value.object.get("dumps").? == .null);
}

test "nothing asked writes an empty list and nulls" {
    var fix: Fixture = undefined;
    try fix.open();
    defer fix.close();
    const regs: Regs = .{};
    const options = Options{ .path = "unused.elf" };
    const of = json_dumps.Dumps{ .registers = .{ .zig = &regs }, .memory = fix.memory(), .image = undefined, .options = &options, .io = std.testing.io };
    var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buf.deinit();
    const doc = try render(&fix.board, &of, &buf);
    defer doc.deinit();
    const dumps = doc.value.object.get("dumps").?.object;
    try std.testing.expectEqual(@as(usize, 0), dumps.get("symbols").?.array.items.len);
    try std.testing.expect(dumps.get("registers").? == .null);
    try std.testing.expect(dumps.get("memory").? == .null);
}

test "registers and memory words read off the core" {
    var fix: Fixture = undefined;
    try fix.open();
    defer fix.close();
    const core = fix.memory();
    try core.writeWord(base, 0x11223344);
    try core.writeWord(base + 4, 0x55667788);
    var file: Regs = .{};
    file.set(0, 42);
    file.setSp(base);
    var spec_buf: [16]u8 = undefined;
    const spec = try std.fmt.bufPrint(&spec_buf, "0x{X}", .{base});
    var options = Options{ .path = "unused.elf", .dump_regs = true, .dump_mem_count = 1 };
    options.dump_mem[0] = .{ .spec = spec, .words = 2 };
    const of = json_dumps.Dumps{ .registers = .{ .zig = &file }, .memory = core, .image = undefined, .options = &options, .io = std.testing.io };
    var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buf.deinit();
    const doc = try render(&fix.board, &of, &buf);
    defer doc.deinit();
    const dumps = doc.value.object.get("dumps").?.object;
    const regs = dumps.get("registers").?.object;
    try std.testing.expectEqual(@as(i64, 42), regs.get("r0").?.integer);
    try std.testing.expectEqual(@as(i64, 0x11223344), regs.get("stack").?.array.items[0].integer);
    const memory = dumps.get("memory").?.object;
    try std.testing.expectEqual(@as(i64, base), memory.get("address").?.integer);
    try std.testing.expect(memory.get("error").? == .null);
    const words = memory.get("words").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), words.len);
    try std.testing.expectEqual(@as(i64, 0x55667788), words[1].integer);
}

test "two --dump-mem places keep memory as the first and list both in order" {
    var fix: Fixture = undefined;
    try fix.open();
    defer fix.close();
    const core = fix.memory();
    const regs: Regs = .{};
    try core.writeWord(base, 0xAAAA0001);
    try core.writeWord(base + 0x40, 0xBBBB0002);
    var first_buf: [16]u8 = undefined;
    var second_buf: [16]u8 = undefined;
    const first = try std.fmt.bufPrint(&first_buf, "0x{X}", .{base + 0x40});
    const second = try std.fmt.bufPrint(&second_buf, "0x{X}", .{base});
    var options = Options{ .path = "unused.elf" };
    options.dump_mem[0] = .{ .spec = first, .words = 1 };
    options.dump_mem[1] = .{ .spec = second, .words = 1 };
    options.dump_mem_count = 2;
    const of = json_dumps.Dumps{ .registers = .{ .zig = &regs }, .memory = core, .image = undefined, .options = &options, .io = std.testing.io };
    var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buf.deinit();
    const doc = try render(&fix.board, &of, &buf);
    defer doc.deinit();
    const dumps = doc.value.object.get("dumps").?.object;
    const memory = dumps.get("memory").?.object;
    try std.testing.expectEqual(@as(i64, base + 0x40), memory.get("address").?.integer);
    const places = dumps.get("memory_places").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), places.len);
    try std.testing.expectEqual(@as(i64, 0xBBBB0002), places[0].object.get("words").?.array.items[0].integer);
    try std.testing.expectEqual(@as(i64, 0xAAAA0001), places[1].object.get("words").?.array.items[0].integer);
}

test {
    _ = @import("regs_test.zig");
}
