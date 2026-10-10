//! Covers turning Windows console key events into SCI bytes (RA8EMU-723).
const std = @import("std");
const ra8 = @import("ra8");
const host_console = ra8.host.host_console;

fn key(char: u16, down: bool, repeat: u16) host_console.InputRecord {
    return .{ .event_type = host_console.key_event, .event = .{ .key = .{
        .key_down = if (down) .TRUE else .FALSE,
        .repeat_count = repeat,
        .virtual_key = 0,
        .virtual_scan = 0,
        .char = char,
        .control_keys = 0,
    } } };
}

test "a key press types its character and Enter types a newline" {
    var out: [4]u8 = undefined;
    var end = host_console.keyBytes(key('a', true, 1), &out, 0);
    end = host_console.keyBytes(key('\r', true, 1), &out, end);
    try std.testing.expectEqualStrings("a\n", out[0..end]);
}

test "releases, bare modifier keys, non-ASCII and other events type nothing" {
    var out: [4]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 0), host_console.keyBytes(key('a', false, 1), &out, 0));
    try std.testing.expectEqual(@as(usize, 0), host_console.keyBytes(key(0, true, 1), &out, 0));
    try std.testing.expectEqual(@as(usize, 0), host_console.keyBytes(key(0xE9, true, 1), &out, 0));
    var resize = key('a', true, 1);
    resize.event_type = 0x0004;
    try std.testing.expectEqual(@as(usize, 0), host_console.keyBytes(resize, &out, 0));
}

test "a held key repeats until the buffer is full" {
    var out: [3]u8 = undefined;
    const end = host_console.keyBytes(key('x', true, 5), &out, 0);
    try std.testing.expectEqualStrings("xxx", out[0..end]);
}
