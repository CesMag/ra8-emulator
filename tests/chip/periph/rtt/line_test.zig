//! Line assembly: what a drained ring turns into.
const std = @import("std");
const ra8 = @import("ra8");
const text = ra8.chip.periph.rtt.line;

fn feed(line: *text.Line, bytes: []const u8) void {
    for (bytes) |byte| line.feed(byte);
}

test "a newline latches a line" {
    var line = text.Line{};
    feed(&line, "boot\n");
    try std.testing.expectEqual(@as(u32, 1), line.lines);
    try std.testing.expectEqualStrings("boot", line.slice());
}

test "a carriage return is not part of the line" {
    var line = text.Line{};
    feed(&line, "boot\r\n");
    try std.testing.expectEqualStrings("boot", line.slice());
}

test "text with no newline is still readable, where dev drops it" {
    var line = text.Line{};
    feed(&line, "half a banner");
    try std.testing.expectEqual(@as(u32, 0), line.lines);
    try std.testing.expectEqualStrings("half a banner", line.pending());
}

test "an over-long line is latched and counted apart from real lines" {
    var line = text.Line{};
    for (0..text.limits.line + 1) |_| line.feed('x');
    try std.testing.expectEqual(@as(u32, 0), line.lines);
    try std.testing.expectEqual(@as(u32, 1), line.wrapped);
    try std.testing.expectEqual(@as(usize, text.limits.line), line.slice().len);
    try std.testing.expectEqual(@as(usize, 1), line.pending().len);
}

test "the byte that forced the wrap starts the next line" {
    var line = text.Line{};
    for (0..text.limits.line) |_| line.feed('x');
    line.feed('y');
    try std.testing.expectEqualStrings("y", line.pending());
}

test "a second line replaces the first" {
    var line = text.Line{};
    feed(&line, "one\ntwo\n");
    try std.testing.expectEqual(@as(u32, 2), line.lines);
    try std.testing.expectEqualStrings("two", line.slice());
}

test "an empty line still counts" {
    var line = text.Line{};
    feed(&line, "\n");
    try std.testing.expectEqual(@as(u32, 1), line.lines);
    try std.testing.expectEqualStrings("", line.slice());
}

test "a fresh assembler is quiet" {
    var line = text.Line{};
    try std.testing.expect(line.quiet());
    line.feed('a');
    try std.testing.expect(!line.quiet());
}
