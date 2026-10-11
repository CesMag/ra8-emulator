//! Host tests for console scrollback (RA8EMU-1122): the wheel and the page
//! keys move through the log, a scrolled-back view holds still as lines
//! arrive, and the shell routes both only when the pointer is over a
//! console leaf.
const std = @import("std");
const gui_app = @import("gui_app");
const console_log = gui_app.console_log;
const console_scroll = gui_app.console_scroll;
const pane_layout = gui_app.pane_layout;
const shell_frame = gui_app.shell_frame;
const shell_loop = gui_app.shell_loop;
const Console = gui_app.shell_console.Console;
const Scroll = console_scroll.Scroll;

fn lines(log: *console_log.Log, count: usize) !void {
    for (0..count) |at| try log.feedAll("line\n", at);
}

test "a wheel turn up goes back three lines and down comes forward" {
    var log = console_log.Log.init(std.testing.allocator, 100);
    defer log.deinit();
    try lines(&log, 10);
    var scroll: Scroll = .{};
    scroll.wheel(1, &log);
    try std.testing.expectEqual(@as(usize, 3), scroll.back);
    scroll.wheel(-1, &log);
    try std.testing.expectEqual(@as(usize, 0), scroll.back);
}

test "the wheel stops at both ends and a fine turn adds up" {
    var log = console_log.Log.init(std.testing.allocator, 100);
    defer log.deinit();
    try lines(&log, 4);
    var scroll: Scroll = .{};
    scroll.wheel(5, &log);
    try std.testing.expectEqual(@as(usize, 4), scroll.back);
    scroll.wheel(-0.2, &log);
    try std.testing.expectEqual(@as(usize, 4), scroll.back);
    scroll.wheel(-0.2, &log);
    try std.testing.expectEqual(@as(usize, 3), scroll.back);
    scroll.wheel(-9, &log);
    try std.testing.expectEqual(@as(usize, 0), scroll.back);
}

test "page keys move a pane of rows and other keys are refused" {
    var log = console_log.Log.init(std.testing.allocator, 100);
    defer log.deinit();
    try lines(&log, 30);
    var scroll: Scroll = .{};
    try std.testing.expect(scroll.page(console_scroll.page_up, 8, &log));
    try std.testing.expectEqual(@as(usize, 8), scroll.back);
    try std.testing.expect(scroll.page(console_scroll.page_down, 5, &log));
    try std.testing.expectEqual(@as(usize, 3), scroll.back);
    try std.testing.expect(!scroll.page('a', 8, &log));
    try std.testing.expectEqual(@as(usize, 3), scroll.back);
}

test "scrolled back, new and dropped lines keep the same lines on screen" {
    var log = console_log.Log.init(std.testing.allocator, 6);
    defer log.deinit();
    try lines(&log, 6);
    var scroll: Scroll = .{};
    scroll.wheel(1, &log);
    try lines(&log, 2);
    scroll.follow(&log);
    try std.testing.expectEqual(@as(usize, 5), scroll.back);
    var bottom: Scroll = .{};
    bottom.follow(&log);
    try lines(&log, 2);
    bottom.follow(&log);
    try std.testing.expectEqual(@as(usize, 0), bottom.back);
}

const Fixture = struct {
    shell: shell_loop.Shell,
    console: Console,
    solved: pane_layout.Solved,

    fn deinit(self: *Fixture) void {
        self.solved.deinit(std.testing.allocator);
        self.console.deinit();
        self.shell.deinit();
    }

    /// The middle of the first leaf of `kind`.
    fn middle(self: *const Fixture, kind: pane_layout.Kind) [2]i32 {
        for (self.solved.panes.items) |placed| {
            const pane = self.shell.layout.pane(placed.index) orelse continue;
            if (pane.kind != kind) continue;
            const body = shell_frame.bodyOf(placed.area);
            return .{ body.x + @divTrunc(body.w, 2), body.y + @divTrunc(body.h, 2) };
        }
        unreachable;
    }
};

fn fixture(fx: *Fixture) !void {
    fx.shell = shell_loop.Shell.init(std.testing.allocator, try pane_layout.twoCore(std.testing.allocator));
    fx.console = Console.init(std.testing.allocator);
    fx.shell.console = &fx.console;
    fx.solved = try fx.shell.layout.solve(std.testing.allocator, .{ .x = 0, .y = 0, .w = 1280, .h = 800 });
    try lines(&fx.console.log, 200);
}

test "the shell scrolls the console only with the pointer over a console leaf" {
    var fx: Fixture = undefined;
    try fixture(&fx);
    defer fx.deinit();
    const board = fx.middle(.board);
    fx.shell.handle(.{ .pointer = .{ .x = board[0], .y = board[1] } }, &fx.solved);
    fx.shell.handle(.{ .wheel = .{ .dx = 0, .dy = 2 } }, &fx.solved);
    try std.testing.expectEqual(@as(usize, 0), fx.console.scroll.back);
    const at = fx.middle(.console);
    fx.shell.handle(.{ .pointer = .{ .x = at[0], .y = at[1] } }, &fx.solved);
    fx.shell.handle(.{ .wheel = .{ .dx = 0, .dy = 2 } }, &fx.solved);
    try std.testing.expectEqual(@as(usize, 6), fx.console.scroll.back);
}

test "page up over a console leaf goes back the rows it shows" {
    var fx: Fixture = undefined;
    try fixture(&fx);
    defer fx.deinit();
    const at = fx.middle(.console);
    fx.shell.handle(.{ .pointer = .{ .x = at[0], .y = at[1] } }, &fx.solved);
    fx.shell.handle(.{ .key = .{ .code = console_scroll.page_up, .down = true } }, &fx.solved);
    try std.testing.expect(fx.console.scroll.back > 0);
    const shown = fx.console.scroll.back;
    fx.shell.handle(.{ .key = .{ .code = console_scroll.page_up, .down = false } }, &fx.solved);
    try std.testing.expectEqual(shown, fx.console.scroll.back);
    fx.shell.handle(.{ .key = .{ .code = console_scroll.page_down, .down = true } }, &fx.solved);
    try std.testing.expectEqual(@as(usize, 0), fx.console.scroll.back);
}
