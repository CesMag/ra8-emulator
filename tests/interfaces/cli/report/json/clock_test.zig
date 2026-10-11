//! Covers src/interfaces/cli/report/json_clock.zig and json_modules.zig:
//! the `clocks` object of `--report json`, parsed back with std.json.
const std = @import("std");
const ra8 = @import("ra8");
const cli_app = @import("cli_app");

const json_run = cli_app.report.json.run;
const Value = std.json.Value;
const Fixture = @import("../json_board.zig").Fixture;

fn clocks(board: *ra8.board.board.Board, buf: *std.Io.Writer.Allocating) !std.json.Parsed(Value) {
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

test "a quiet board has every clocks key" {
    var fix: Fixture = undefined;
    try fix.open();
    defer fix.close();
    var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buf.deinit();
    const doc = try clocks(&fix.board, &buf);
    defer doc.deinit();
    const top = doc.value.object.get("clocks").?;
    try has(top, &.{ "system", "pll", "voltage", "low_power", "monitors", "selects", "dividers", "oscillators", "sub_clock", "memory_rates", "module_stop" });
    const system = top.object.get("system").?;
    try has(system, &.{ "source", "programmed", "dropped_locked", "unstable_selects", "reserved_selects", "domains" });
    const domains = system.object.get("domains").?.array.items;
    try std.testing.expect(domains.len != 0);
    try has(domains[0], &.{ "name", "ratio", "code" });
    const pll = top.object.get("pll").?;
    try has(pll, &.{ "pll1", "pll2", "main_oscillator_wait_code", "dropped_locked" });
    try has(pll.object.get("pll1").?, &.{ "configured", "source", "input_ratio", "multiplier_whole", "multiplier_hundredths", "p_ratio", "q_ratio", "r_ratio", "dropped_running", "prohibited_divider" });
    try has(top.object.get("voltage").?, &.{ "stores", "range", "transitions", "dropped_locked", "flag_writes", "pll_selects_hazard", "pll_selects_safe" });
    try has(top.object.get("low_power").?, &.{ "stores", "lpscr", "wfi_state", "bus_output_kept", "io_kept", "soft_start", "dropped_locked", "standby_selects", "undefined_modes", "prohibited_softstart" });
    try has(top.object.get("monitors").?, &.{ "refused_filter_changes", "refused_rise_bands", "refused_negations", "dropped_locked", "channels" });
    try has(top.object.get("selects").?, &.{ "dropped_locked", "branches" });
    try has(top.object.get("dividers").?, &.{ "dropped_locked", "branches" });
    try has(top.object.get("oscillators").?, &.{ "starts", "stops", "oscsf", "refused_flag_stores", "dropped_locked" });
    try has(top.object.get("sub_clock").?, &.{ "running", "drive", "starts", "refused_running", "dropped_locked" });
    try has(top.object.get("memory_rates").?, &.{ "mriclk_mhz", "mrpclk_mhz", "prefetch_on", "refused_keys", "hot_changes", "early_enables" });
    const stop = top.object.get("module_stop").?;
    try has(stop, &.{ "clean", "stopped_reads", "stopped_writes", "last_stopped", "probed_reads", "probed_writes", "last_probed" });
    try std.testing.expectEqual(@as(usize, 0), top.object.get("selects").?.object.get("branches").?.array.items.len);
}

test "a touched clock select is listed by name with its counts" {
    var fix: Fixture = undefined;
    try fix.open();
    defer fix.close();
    fix.board.branches.selects[0].requests = 3;
    fix.board.branches.selects[0].switches = 1;
    var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buf.deinit();
    const doc = try clocks(&fix.board, &buf);
    defer doc.deinit();
    const list = doc.value.object.get("clocks").?.object.get("selects").?.object.get("branches").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), list.len);
    try std.testing.expectEqual(@as(i64, 3), list[0].object.get("requests").?.integer);
    try std.testing.expectEqual(@as(i64, 1), list[0].object.get("switches").?.integer);
    try std.testing.expect(list[0].object.get("name").? == .string);
}
