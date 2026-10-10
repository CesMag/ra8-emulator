//! Tests for src/session/touch_spec.zig, through the flag that uses it.
const std = @import("std");
const parse = @import("cli_app").cli.parse;

test "a touch spec is X,Y in panel coordinates" {
    const options = try parse(&[_][]const u8{ "emu", "a.elf", "--touch", "120,48" });
    try std.testing.expectEqual(@as(usize, 1), options.touch_count);
    try std.testing.expectEqual(@as(u16, 120), options.touches[0].x);
    try std.testing.expectEqual(@as(u16, 48), options.touches[0].y);
}

test "a touch spec with no comma or a bad number is refused" {
    try std.testing.expectError(error.BadTouch, parse(&[_][]const u8{ "emu", "a.elf", "--touch", "120" }));
    try std.testing.expectError(error.InvalidCharacter, parse(&[_][]const u8{ "emu", "a.elf", "--touch", "x,4" }));
}

test "a touch sequence queues every X:Y point in order" {
    const options = try parse(&[_][]const u8{ "emu", "a.elf", "--touch-seq", "420:520,3868:520,2148:2248" });
    try std.testing.expectEqual(@as(usize, 3), options.touch_count);
    try std.testing.expectEqual(@as(u16, 3868), options.touches[1].x);
    try std.testing.expectEqual(@as(u16, 2248), options.touches[2].y);
}

test "a touch sequence with a bad point or too many points is refused" {
    try std.testing.expectError(error.BadTouch, parse(&[_][]const u8{ "emu", "a.elf", "--touch-seq", "1:2,3" }));
    try std.testing.expectError(error.TooManyTouches, parse(&[_][]const u8{ "emu", "a.elf", "--touch-seq", "1:1,2:2,3:3,4:4,5:5,6:6,7:7,8:8,9:9" }));
}
