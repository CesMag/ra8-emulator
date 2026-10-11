//! Covers src/interfaces/gui/console/log.zig: lines end on newline with the virtual
//! time they ended at, carriage returns drop, long lines stop growing, the
//! scrollback drops its oldest line, and a save writes stamped text.
const std = @import("std");
const gui_app = @import("gui_app");
const console_log = gui_app.console.log;

test "a newline finishes the line at the time it arrived" {
    var log = console_log.Log.init(std.testing.allocator, 8);
    defer log.deinit();
    try log.feedAll("boot\r\n", 1_000);
    try log.feedAll("ready", 2_000);
    try log.feed('\n', 3_500);
    try std.testing.expectEqual(@as(usize, 2), log.lines().len);
    try std.testing.expectEqualStrings("boot", log.lines()[0].text);
    try std.testing.expectEqual(@as(u64, 1_000), log.lines()[0].at_ns);
    try std.testing.expectEqualStrings("ready", log.lines()[1].text);
    try std.testing.expectEqual(@as(u64, 3_500), log.lines()[1].at_ns);
    try std.testing.expectEqualStrings("", log.partial());
}

test "a line past the limit stops growing instead of wrapping" {
    var log = console_log.Log.init(std.testing.allocator, 2);
    defer log.deinit();
    for (0..console_log.max_line + 40) |_| try log.feed('x', 0);
    try std.testing.expectEqual(console_log.max_line, log.partial().len);
    try log.feed('\n', 9);
    try std.testing.expectEqual(console_log.max_line, log.lines()[0].text.len);
}

test "the scrollback keeps the newest lines and counts the ones it dropped" {
    var log = console_log.Log.init(std.testing.allocator, 2);
    defer log.deinit();
    try log.feedAll("one\ntwo\nthree\n", 5);
    try std.testing.expectEqual(@as(usize, 2), log.lines().len);
    try std.testing.expectEqualStrings("two", log.lines()[0].text);
    try std.testing.expectEqualStrings("three", log.lines()[1].text);
    try std.testing.expectEqual(@as(u64, 1), log.dropped);
}

test "a save writes each line, stamped in virtual seconds when asked" {
    var log = console_log.Log.init(std.testing.allocator, 4);
    defer log.deinit();
    try log.feedAll("hello\n", 12_000_345_678);
    try log.feedAll("tail", 13_000_000_000);
    var buf: [128]u8 = undefined;
    var stream: std.Io.Writer = .fixed(&buf);
    try log.save(&stream, true);
    try std.testing.expectEqualStrings("[  12.000345678] hello\ntail\n", stream.buffered());
    stream.end = 0;
    try log.save(&stream, false);
    try std.testing.expectEqualStrings("hello\ntail\n", stream.buffered());
}
