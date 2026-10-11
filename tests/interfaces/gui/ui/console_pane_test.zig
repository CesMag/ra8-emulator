//! Covers src/interfaces/gui/ui/console_pane.zig: the newest lines that fit are drawn
//! with their stamps, the unfinished line shows last without one, a strip
//! too short for a row draws nothing, the strip sits under the board, and
//! it rasterises to a pinned golden frame in both palettes.
const std = @import("std");
const dark = &@import("gui_app").colors.palettes.dark;
const light = &@import("gui_app").colors.palettes.light;
const ra8 = @import("ra8");
const gui_app = @import("gui_app");
const console_log = gui_app.console_log;
const console_pane = gui_app.console_pane;
const draw_list = ra8.render.draw_list;
const raster = ra8.render.raster;

/// Glyph commands in `list`.
fn glyphs(list: *const draw_list.DrawList) usize {
    var count: usize = 0;
    for (list.commands.items) |command| {
        if (command.shape == .glyph) count += 1;
    }
    return count;
}

/// Two rows: 2 * pad + 2 * cell_h, plus a spare pixel.
const two_rows = draw_list.Rect{ .x = 0, .y = 0, .w = 400, .h = 2 * console_pane.pad + 2 * 8 + 1 };

test "only the newest lines that fit are drawn, each stamped" {
    var log = console_log.Log.init(std.testing.allocator, 8);
    defer log.deinit();
    try log.feedAll("a\n", 1_000_000_000);
    try log.feedAll("bb\n", 2_000_000_000);
    try log.feedAll("ccc\n", 3_000_000_000);
    var list = draw_list.DrawList.init(std.testing.allocator, 400, 100);
    defer list.deinit();
    try console_pane.draw(&list, dark, two_rows, &log, 0);
    try std.testing.expectEqual(@as(usize, 2), console_pane.rows(two_rows));
    // "[   2.000000000] " has 13 glyphs; then "bb" and "ccc".
    try std.testing.expectEqual(@as(usize, 13 + 2 + 13 + 3), glyphs(&list));
}

test "the unfinished line takes the last row without a stamp" {
    var log = console_log.Log.init(std.testing.allocator, 8);
    defer log.deinit();
    try log.feedAll("done\n", 1_000_000_000);
    try log.feedAll("typing", 2_000_000_000);
    var list = draw_list.DrawList.init(std.testing.allocator, 400, 100);
    defer list.deinit();
    try console_pane.draw(&list, dark, two_rows, &log, 0);
    try std.testing.expectEqual(@as(usize, 13 + 4 + 6), glyphs(&list));
}

test "a strip with no room for a row draws nothing" {
    var log = console_log.Log.init(std.testing.allocator, 8);
    defer log.deinit();
    try log.feedAll("hidden\n", 1_000_000_000);
    var list = draw_list.DrawList.init(std.testing.allocator, 400, 100);
    defer list.deinit();
    try console_pane.draw(&list, dark, .{ .x = 0, .y = 0, .w = 400, .h = 10 }, &log, 0);
    try std.testing.expectEqual(@as(usize, 0), list.commands.items.len);
}

test "the strip starts under the board view and runs to the window's foot" {
    const area = console_pane.under(1056, 696, 860);
    try std.testing.expectEqual(@as(i32, 700), area.y);
    try std.testing.expectEqual(@as(i32, 160), area.h);
    try std.testing.expectEqual(@as(i32, 1056), area.w);
    try std.testing.expect(console_pane.rows(area) >= 18);
    try std.testing.expectEqual(@as(i32, 0), console_pane.under(1056, 696, 690).h);
}

test "scrolled back, the lines ending there show and the unfinished one hides" {
    var log = console_log.Log.init(std.testing.allocator, 8);
    defer log.deinit();
    try log.feedAll("a\n", 1_000_000_000);
    try log.feedAll("bb\n", 2_000_000_000);
    try log.feedAll("ccc\n", 3_000_000_000);
    try log.feedAll("typing", 4_000_000_000);
    var list = draw_list.DrawList.init(std.testing.allocator, 400, 100);
    defer list.deinit();
    try console_pane.draw(&list, dark, two_rows, &log, 1);
    try std.testing.expectEqual(@as(usize, 13 + 1 + 13 + 2), glyphs(&list));
}

test "scrolled past the oldest line, the pane still fills from the top" {
    var log = console_log.Log.init(std.testing.allocator, 8);
    defer log.deinit();
    try log.feedAll("a\n", 1_000_000_000);
    try log.feedAll("bb\n", 2_000_000_000);
    try log.feedAll("ccc\n", 3_000_000_000);
    var list = draw_list.DrawList.init(std.testing.allocator, 400, 100);
    defer list.deinit();
    try console_pane.draw(&list, dark, two_rows, &log, 3);
    try std.testing.expectEqual(@as(usize, 13 + 1 + 13 + 2), glyphs(&list));
}

/// Three finished lines and an unfinished one, rasterised in `theme`.
fn consoleDigest(theme: *const gui_app.colors.Theme) !u64 {
    var log = console_log.Log.init(std.testing.allocator, 8);
    defer log.deinit();
    try log.feedAll("boot\n", 1_000_000_000);
    try log.feedAll("uart echo ready\n", 2_000_000_000);
    try log.feedAll("> hello\n", 3_000_000_000);
    try log.feedAll("> wor", 4_000_000_000);
    const area = draw_list.Rect{ .x = 0, .y = 0, .w = 240, .h = 2 * console_pane.pad + 4 * 8 + 1 };
    var list = draw_list.DrawList.init(std.testing.allocator, 240, @intCast(area.h));
    defer list.deinit();
    var frame = try raster.Framebuffer.init(std.testing.allocator, 240, @intCast(area.h));
    defer frame.deinit(std.testing.allocator);
    try console_pane.draw(&list, theme, area, &log, 0);
    raster.draw(&frame, &list, ra8.render.font.atlas);
    return std.hash.Fnv1a_64.hash(std.mem.sliceAsBytes(frame.pixels));
}

test "the strip rasterises to a pinned golden frame in each palette" {
    try std.testing.expectEqual(@as(u64, 3468250555529406939), try consoleDigest(dark));
    try std.testing.expectEqual(@as(u64, 6000875149775368540), try consoleDigest(light));
}
