//! Covers src/chip/periph/sci/line.zig: the console line the firmware printed.
const std = @import("std");
const ra8 = @import("ra8");
const text = ra8.chip.periph.sci.line;

const Transcript = struct {
    bytes: [64]u8 = undefined,
    len: usize = 0,
};

fn collect(context: ?*anyopaque, line: []const u8) anyerror!void {
    const transcript: *Transcript = @ptrCast(@alignCast(context.?));
    @memcpy(transcript.bytes[transcript.len .. transcript.len + line.len], line);
    transcript.len += line.len;
    transcript.bytes[transcript.len] = '|';
    transcript.len += 1;
}

test "the sink receives each line when its newline arrives" {
    var transcript = Transcript{};
    var line = text.Line{};
    line.setSink(.{ .context = &transcript, .writeFn = collect });
    for ("first\nsecond") |byte| line.feed(byte);
    try std.testing.expectEqualStrings("first|", transcript.bytes[0..transcript.len]);
    line.feed('\n');
    try std.testing.expectEqualStrings("first|second|", transcript.bytes[0..transcript.len]);
    try std.testing.expect(!line.sink_failed);
}

test "a line is latched on the newline that finishes it" {
    var line = text.Line{};
    for ("hello, ra8d2!\r\n") |byte| line.feed(byte);
    try std.testing.expectEqualStrings("hello, ra8d2!", line.slice());
    try std.testing.expectEqual(@as(u32, 1), line.lines);
}

test "an unfinished line is not latched until its newline arrives" {
    var line = text.Line{};
    for ("first\nsecond") |byte| line.feed(byte);
    try std.testing.expectEqualStrings("first", line.slice());
    line.feed('\n');
    try std.testing.expectEqualStrings("second", line.slice());
    try std.testing.expectEqual(@as(u32, 2), line.lines);
}

test "an over-long line stops growing rather than wrapping onto itself" {
    var line = text.Line{};
    for (0..text.limits.line + 8) |_| line.feed('a');
    line.feed('\n');
    try std.testing.expectEqual(text.limits.line, line.slice().len);
}

test "a carriage return never reaches the line" {
    var line = text.Line{};
    for ("a\rb\n") |byte| line.feed(byte);
    try std.testing.expectEqualStrings("ab", line.slice());
}
