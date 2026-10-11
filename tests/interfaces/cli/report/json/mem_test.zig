//! Covers src/interfaces/cli/report/json_mem.zig: the `memory` object of
//! `--report json`, parsed back with std.json.
const std = @import("std");
const ra8 = @import("ra8");
const cli_app = @import("cli_app");

const json_run = cli_app.report.json.run;
const Value = std.json.Value;
const Fixture = @import("../json_board.zig").Fixture;

fn memory(board: *ra8.board.board.Board, buf: *std.Io.Writer.Allocating) !std.json.Parsed(Value) {
    try json_run.document(&buf.writer, board, .{ .engine = "zig", .elapsed = 1 });
    return std.json.parseFromSlice(Value, std.testing.allocator, buf.written(), .{});
}

fn int(object: Value, key: []const u8) !i64 {
    return switch (object.object.get(key) orelse return error.MissingKey) {
        .integer => |n| n,
        else => error.NotInteger,
    };
}

fn tag(object: Value, key: []const u8) !std.meta.Tag(Value) {
    return std.meta.activeTag(object.object.get(key) orelse return error.MissingKey);
}

test "a quiet board has every memory key and empty lists" {
    var fix: Fixture = undefined;
    try fix.open();
    defer fix.close();
    const board = &fix.board;
    var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buf.deinit();
    const doc = try memory(board, &buf);
    defer doc.deinit();
    const top = doc.value.object.get("memory").?;
    const cache = top.object.get("cache").?;
    for ([_][]const u8{ "line_bytes", "ctr", "refused_stores" }) |key| _ = try int(cache, key);
    for ([_][]const u8{ "icache_on", "dcache_on", "set_way_walk_declined" }) |key| try std.testing.expectEqual(.bool, try tag(cache, key));
    try std.testing.expectEqual(@as(usize, 0), cache.object.get("maintenance").?.array.items.len);
    const sram = top.object.get("sram").?;
    for ([_][]const u8{ "ecc_latches", "sramesr", "refused_esr_stores", "prcr_key_writes", "prcr_guarded_stores", "prcr_ignored_keys", "prcr_refused_stores" }) |key| _ = try int(sram, key);
    try std.testing.expectEqual(.bool, try tag(sram, "prcr_unlocked"));
    const dmac = top.object.get("dmac").?;
    for ([_][]const u8{ "requests", "units", "bytes", "finished", "cut_short", "still_armed", "refused" }) |key| try std.testing.expectEqual(@as(i64, 0), try int(dmac, key));
    try std.testing.expectEqual(.null, try tag(dmac, "last_refusal"));
    try std.testing.expectEqual(@as(usize, 0), dmac.object.get("channels").?.array.items.len);
    const dtc1 = top.object.get("dtc1").?;
    for ([_][]const u8{ "activations", "units", "bytes", "finished", "dtcvbr", "interrupts_held", "refused" }) |key| _ = try int(dtc1, key);
    try std.testing.expectEqual(.null, try tag(dtc1, "last_refusal"));
    const work = top.object.get("unmodelled").?;
    try std.testing.expectEqual(@as(i64, 0), try int(work, "total"));
    try std.testing.expectEqual(@as(usize, 0), work.object.get("lowest").?.array.items.len);
    const regions = top.object.get("external_regions").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), regions.len);
    for (regions) |region| {
        for ([_][]const u8{
            "name",                        "base",          "size_bytes",                    "bus_width_bits",                 "clock_hz",
            "latency_cycles",              "burst",         "memory_window_cycles",          "read_high_water_bytes",          "write_high_water_bytes",
            "bytes_read",                  "bytes_written", "average_read_bytes_per_second", "average_write_bytes_per_second", "peak_read_bytes_per_second",
            "peak_write_bytes_per_second", "stall_cycles",
        }) |key| try std.testing.expect(region.object.get(key) != null);
    }
}

test "external region report exposes timed access counters" {
    var fix: Fixture = undefined;
    try fix.open();
    defer fix.close();
    var config = ra8.board.external.memory.Config{};
    config.ospi.size = 1024 * 1024;
    config.sdram.size = 1024 * 1024;
    try fix.board.nor.resize(config.ospi.size);
    var external = try ra8.board.external.backing.Backing.init(try ra8.board.external.memory.Layout.init(config), fix.board.nor.window());
    defer external.deinit();
    fix.store.attachExternal(external.port());
    const cpu = fix.memory().asInitiator(.cpu0);
    var bytes: [4]u8 = undefined;
    try cpu.read(0x6800_0010, &bytes);
    var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buf.deinit();
    try json_run.document(&buf.writer, &fix.board, .{
        .engine = "zig",
        .elapsed = 1,
        .elapsed_cycles = 100,
        .external = cpu,
    });
    const doc = try std.json.parseFromSlice(Value, std.testing.allocator, buf.written(), .{});
    defer doc.deinit();
    const regions = doc.value.object.get("memory").?.object.get("external_regions").?.array.items;
    const sdram = regions[1];
    try std.testing.expectEqual(@as(i64, 4), try int(sdram, "bytes_read"));
    try std.testing.expectEqual(@as(i64, 0x14), try int(sdram, "read_high_water_bytes"));
    try std.testing.expect(try int(sdram.object.get("stall_cycles").?, "cpu") > 0);
}

test "a busy DMAC channel is listed with its index, shape and counts" {
    var fix: Fixture = undefined;
    try fix.open();
    defer fix.close();
    const board = &fix.board;
    board.dma.channels[3].requests = 2;
    board.dma.channels[3].units = 8;
    board.dma.channels[3].bytes = 32;
    board.dma.channels[3].dmsar = 0x2200_0000;
    var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buf.deinit();
    const doc = try memory(board, &buf);
    defer doc.deinit();
    const dmac = doc.value.object.get("memory").?.object.get("dmac").?;
    try std.testing.expectEqual(@as(i64, 2), try int(dmac, "requests"));
    try std.testing.expectEqual(@as(i64, 32), try int(dmac, "bytes"));
    const list = dmac.object.get("channels").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), list.len);
    try std.testing.expectEqual(@as(i64, 3), try int(list[0], "index"));
    try std.testing.expectEqual(@as(i64, 0x2200_0000), try int(list[0], "dmsar"));
    try std.testing.expectEqual(.string, try tag(list[0], "mode"));
    try std.testing.expectEqual(.string, try tag(list[0], "width"));
    for ([_][]const u8{ "units", "finished", "dmdar", "cut_short", "units_owed" }) |key| _ = try int(list[0], key);
}
