//! Host tests for saving the console log (RA8EMU-1122): a save writes the
//! stamped log to console.txt and replaces the last one, the strip puts the
//! save tab at its right end, and a click on that tab saves through the
//! shell while one elsewhere, or before any output, does not.
const std = @import("std");
const gui_app = @import("gui_app");
const draw_list = @import("ra8").render.draw_list;
const console_log = gui_app.console_log;
const console_save = gui_app.console_save;
const console_strip = gui_app.console_strip;
const pane_layout = gui_app.pane_layout;
const shell_frame = gui_app.shell_frame;
const shell_loop = gui_app.shell_loop;
const Console = gui_app.shell_console.Console;

const io = std.testing.io;

fn readBack(dir: std.Io.Dir, buffer: []u8) ![]const u8 {
    return dir.readFile(io, console_save.file_name, buffer);
}

test "a save writes every stamped line and the unfinished one" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var log = console_log.Log.init(std.testing.allocator, 10);
    defer log.deinit();
    try log.feedAll("boot\n", 1_500_000_000);
    try log.feedAll("half", 2_000_000_000);
    try console_save.save(.{ .io = io, .dir = tmp.dir }, &log);
    var buffer: [256]u8 = undefined;
    try std.testing.expectEqualStrings("[   1.500000000] boot\nhalf\n", try readBack(tmp.dir, &buffer));
}

test "a second save replaces the first" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var log = console_log.Log.init(std.testing.allocator, 10);
    defer log.deinit();
    try log.feedAll("one\ntwo\nthree\n", 0);
    try console_save.save(.{ .io = io, .dir = tmp.dir }, &log);
    var short = console_log.Log.init(std.testing.allocator, 10);
    defer short.deinit();
    try short.feedAll("x\n", 0);
    try std.testing.expectEqual(console_save.Outcome.saved, console_save.attempt(.{ .io = io, .dir = tmp.dir }, &short));
    var buffer: [256]u8 = undefined;
    try std.testing.expectEqualStrings("[   0.000000000] x\n", try readBack(tmp.dir, &buffer));
}

test "the save tab sits at the strip's right end and the log goes under it" {
    const area: draw_list.Rect = .{ .x = 10, .y = 20, .w = 300, .h = 100 };
    const tab = console_strip.saveTab(area);
    try std.testing.expectEqual(area.x + area.w, tab.x + tab.w);
    try std.testing.expectEqual(console_strip.tab_w, tab.w);
    try std.testing.expectEqual(console_strip.strip_h, tab.h);
    const log = console_strip.below(area);
    try std.testing.expectEqual(area.y + console_strip.strip_h, log.y);
    try std.testing.expectEqual(area.h - console_strip.strip_h, log.h);
    const narrow = console_strip.saveTab(.{ .x = 0, .y = 0, .w = console_strip.tab_w - 1, .h = 100 });
    try std.testing.expectEqual(@as(i32, 0), narrow.w);
    const flat = console_strip.below(.{ .x = 0, .y = 0, .w = 300, .h = console_strip.strip_h - 1 });
    try std.testing.expectEqual(console_strip.strip_h - 1, flat.h);
}

test "labels name the last outcome and fit the tab" {
    for ([_]console_save.Outcome{ .none, .saved, .failed }) |outcome| {
        try std.testing.expect(outcome.label().len <= console_save.label_len);
    }
    try std.testing.expectEqualStrings("SAVE", console_save.Outcome.none.label());
}

fn consoleBody(shell: *const shell_loop.Shell, solved: *const pane_layout.Solved) draw_list.Rect {
    for (solved.panes.items) |placed| {
        const pane = shell.layout.pane(placed.index) orelse continue;
        if (pane.kind == .console) return shell_frame.bodyOf(placed.area);
    }
    unreachable;
}

test "a click on the save tab saves through the shell, elsewhere it does not" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var shell = shell_loop.Shell.init(std.testing.allocator, try pane_layout.twoCore(std.testing.allocator));
    defer shell.deinit();
    var console = Console.init(std.testing.allocator);
    defer console.deinit();
    console.save_to = .{ .io = io, .dir = tmp.dir };
    shell.console = &console;
    var solved = try shell.layout.solve(std.testing.allocator, .{ .x = 0, .y = 0, .w = 1280, .h = 800 });
    defer solved.deinit(std.testing.allocator);
    const tab = console_strip.saveTab(consoleBody(&shell, &solved));
    const x = tab.x + @divTrunc(tab.w, 2);
    const y = tab.y + @divTrunc(tab.h, 2);
    shell.handle(.{ .button = .{ .button = 1, .down = true, .x = x, .y = y } }, &solved);
    try std.testing.expectEqual(console_save.Outcome.none, console.saved);
    try console.log.feedAll("ready\n", 0);
    shell.handle(.{ .button = .{ .button = 1, .down = true, .x = tab.x - 20, .y = y } }, &solved);
    try std.testing.expectEqual(console_save.Outcome.none, console.saved);
    shell.handle(.{ .button = .{ .button = 1, .down = true, .x = x, .y = y } }, &solved);
    try std.testing.expectEqual(console_save.Outcome.saved, console.saved);
    var buffer: [64]u8 = undefined;
    try std.testing.expectEqualStrings("[   0.000000000] ready\n", try readBack(tmp.dir, &buffer));
}
