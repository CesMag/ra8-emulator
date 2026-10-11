//! Covers src/interfaces/cli/report/json_glcdc/json_glcdc.zig and json_glcdc/out.zig:
//! the `graphics` object of `--report json`, parsed back with std.json.
const std = @import("std");
const ra8 = @import("ra8");
const cli_app = @import("cli_app");

const json_run = cli_app.report.json_run;
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

test "a quiet board has every graphics key and no framebuffer" {
    var fix: Fixture = undefined;
    try fix.open();
    defer fix.close();
    var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buf.deinit();
    const doc = try render(&fix.board, &buf);
    defer doc.deinit();
    const gfx = doc.value.object.get("graphics").?;
    try has(gfx, &.{ "domain", "glcdc" });
    try has(gfx.object.get("domain").?, &.{ "powered", "power_ons", "power_offs", "dropped_locked" });
    const glcdc = gfx.object.get("glcdc").?;
    try has(glcdc, &.{ "writes", "vblank_updates", "dropped_unpowered", "dark_reads", "framebuffer", "palettes", "timing", "layers", "mixer", "scan", "output", "system" });
    try std.testing.expect(glcdc.object.get("framebuffer").? == .null);
    try std.testing.expectEqual(@as(usize, 0), glcdc.object.get("palettes").?.array.items.len);
    try std.testing.expectEqual(@as(usize, 0), glcdc.object.get("layers").?.array.items.len);
    const timing = glcdc.object.get("timing").?;
    try has(timing, &.{ "tcon_writes", "panel", "layer_clipped", "pins" });
    try std.testing.expect(timing.object.get("panel").? == .null);
    try has(glcdc.object.get("mixer").?, &.{ "mixes", "overlapped", "background" });
    try has(glcdc.object.get("scan").?, &.{ "picture", "refused_no_palette", "refused_off_ram", "refused_too_big", "output_off", "faults" });
    try has(glcdc.object.get("output").?, &.{ "bus", "dither", "gamma", "pixels", "narrowed", "dithered", "gamma_corrected", "clipped", "uncommitted" });
    try has(glcdc.object.get("system").?, &.{ "clocked", "source", "divider", "frames", "refused_unclocked", "stmon", "armed", "enabled", "detections", "would_pend", "undetected", "underflows", "stale_clears", "refused_stmon_writes" });
}

test "a GLCDC that took writes reports them" {
    var fix: Fixture = undefined;
    try fix.open();
    defer fix.close();
    fix.board.display.writes = 7;
    var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buf.deinit();
    const doc = try render(&fix.board, &buf);
    defer doc.deinit();
    const glcdc = doc.value.object.get("graphics").?.object.get("glcdc").?;
    try std.testing.expectEqual(@as(i64, 7), glcdc.object.get("writes").?.integer);
}
