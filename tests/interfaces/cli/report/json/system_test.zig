//! Covers src/interfaces/cli/report/json_system.zig, json_options.zig and
//! json_analog.zig: the `icu`, `pinfunc`, `options`, `part`, `backup` and
//! `analog` objects of `--report json`, parsed back with std.json.
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

fn has(object: Value, keys: []const []const u8) !void {
    for (keys) |key| {
        if (object.object.get(key) == null) {
            std.debug.print("missing key {s}\n", .{key});
            return error.MissingKey;
        }
    }
}

test "a quiet board has every icu, pinfunc, options, part, backup and analog key" {
    var fix: Fixture = undefined;
    try fix.open();
    defer fix.close();
    var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buf.deinit();
    const doc = try render(&fix.board, &buf);
    defer doc.deinit();
    const root = doc.value;
    try has(root.object.get("icu").?, &.{ "raised", "pended", "unrouted", "repended", "irq_pins_configured", "irq_pin_rewrites_while_routed" });
    try has(root.object.get("pinfunc").?, &.{ "programmed", "refused_unlocked", "glitched", "ignored_keys" });
    try has(root.object.get("options").?, &.{ "programs", "config_sets", "live_cells", "rejected_outside_window", "refused_command_locked", "refused_paused", "refused_outside_mode", "refused_malformed", "refused_otp_rewrites", "refused_mentryr_keyless", "refused_mentryr_narrow", "setup_inits", "refused_msuinitr_keyless", "refused_msuinitr_narrow", "refused_status_stores", "refused_mrcps_stores", "lost_programs" });
    const part = root.object.get("part").?;
    try has(part, &.{ "name", "mram_base", "mram_bytes", "sram_base", "sram_bytes", "cpu0_tcm_bytes", "cpu0_cache_bytes", "cpu1_tcm_bytes", "cpu1_cache_bytes", "source" });
    try std.testing.expect(part.object.get("mram_bytes").?.integer > 0);
    const backup = root.object.get("backup").?;
    try has(backup, &.{ "prcr", "vbtbkr_writes", "dropped_locked", "dropped_disabled", "last_drop", "control" });
    try has(backup.object.get("prcr").?, &.{ "unlocks", "rejected_keys", "groups" });
    try has(backup.object.get("control").?, &.{ "writes", "flags_cleared", "vbae", "refused", "dropped_locked" });
    const analog = root.object.get("analog").?;
    try std.testing.expectEqual(@as(usize, 0), analog.object.get("dac").?.array.items.len);
    try std.testing.expectEqual(@as(usize, 0), analog.object.get("comparators").?.array.items.len);
    try has(analog.object.get("adc").?, &.{ "scans", "converted", "last_code", "refused_disabled", "refused_fake_results", "empty_scans", "unbacked", "stops", "masked" });
}

test "event and pin counts carry through" {
    var fix: Fixture = undefined;
    try fix.open();
    defer fix.close();
    fix.board.events.raised = 4;
    fix.board.pinfunc.programmed = 9;
    var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buf.deinit();
    const doc = try render(&fix.board, &buf);
    defer doc.deinit();
    try std.testing.expectEqual(@as(i64, 4), doc.value.object.get("icu").?.object.get("raised").?.integer);
    try std.testing.expectEqual(@as(i64, 9), doc.value.object.get("pinfunc").?.object.get("programmed").?.integer);
}
