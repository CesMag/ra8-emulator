//! Covers src/interfaces/cli/report/json_drw.zig and json_media.zig: the
//! `drw` and `eink` keys of `graphics`, and the `audio`, `mipi_phy` and
//! `capture` objects of `--report json`, parsed back with std.json.
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

test "a quiet board has every drw, eink, audio, mipi_phy and capture key" {
    var fix: Fixture = undefined;
    try fix.open();
    defer fix.close();
    var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buf.deinit();
    const doc = try render(&fix.board, &buf);
    defer doc.deinit();
    const gfx = doc.value.object.get("graphics").?;
    const drw = gfx.object.get("drw").?;
    try has(drw, &.{ "renders", "last_width", "last_height", "pixels", "limited", "clipped", "hard_edges", "display_lists", "display_list_stops", "declined", "last_decline", "faults", "dropped_unpowered", "dark_reads", "texture", "cache" });
    try std.testing.expect(drw.object.get("last_decline").? == .null);
    try has(drw.object.get("texture").?, &.{ "texels", "keyed", "wrapped", "refused_off_ram", "faults" });
    try has(drw.object.get("cache").?, &.{ "held", "written_back", "flushes", "evicted", "forwarded", "still_held", "disabled_dirty", "faults" });
    const eink = gfx.object.get("eink").?;
    try has(eink, &.{ "commands", "pixels", "refreshes", "last_waveform", "vcom_mv", "awake", "refused_asleep", "refused_overrun", "load_width", "load_height", "overdrain", "stray", "read_only_writes", "spilled", "film" });
    try has(eink.object.get("film").?, &.{ "started", "settled", "busy_polls", "idle_polls", "unsettled", "overlapped" });
    const audio = doc.value.object.get("audio").?;
    try std.testing.expectEqual(@as(usize, 0), audio.object.get("ssie").?.array.items.len);
    try std.testing.expectEqual(@as(usize, 0), audio.object.get("pdm").?.array.items.len);
    const phy = doc.value.object.get("mipi_phy").?;
    try has(phy, &.{ "touched", "mode", "status", "refclk_mhz", "power_ups", "pll_locks", "flag_polls", "dark_polls", "lane_enables", "early_enables", "ignored_pll_stores", "refused_sfr_stores" });
    try std.testing.expect(!phy.object.get("touched").?.bool);
    const cam = doc.value.object.get("capture").?;
    try has(cam, &.{ "arms", "frames", "last_width", "last_lines", "last_bytes", "declined", "last_decline", "short_frames", "short_lines", "short_bytes", "refused_fake_end" });
}

test "a capture that armed reports its counts" {
    var fix: Fixture = undefined;
    try fix.open();
    defer fix.close();
    fix.board.capture.arms = 3;
    fix.board.raster.renders = 5;
    var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buf.deinit();
    const doc = try render(&fix.board, &buf);
    defer doc.deinit();
    try std.testing.expectEqual(@as(i64, 3), doc.value.object.get("capture").?.object.get("arms").?.integer);
    const drw = doc.value.object.get("graphics").?.object.get("drw").?;
    try std.testing.expectEqual(@as(i64, 5), drw.object.get("renders").?.integer);
}
