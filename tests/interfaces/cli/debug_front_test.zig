//! Which command lines the debugger front end takes over.
const std = @import("std");
const cli_app = @import("cli_app");

const debug_front = cli_app.debug_front;

test "an ordinary run is left to the ordinary parser" {
    try std.testing.expectEqual(null, debug_front.wanted(&.{ "ra8_emulator", "fw.elf", "--ms", "2" }));
}

test "a script and the terminal are both asked for after the image" {
    const scripted = try debug_front.wanted(&.{ "ra8_emulator", "fw.elf", "--debug-script", "s.gdb" }).?;
    try std.testing.expectEqualStrings("s.gdb", scripted.mode.script);
    try std.testing.expectEqual(null, scripted.cpu1);
    const typed = try debug_front.wanted(&.{ "ra8_emulator", "fw.elf", "--debug" }).?;
    try std.testing.expectEqual(debug_front.Mode.interactive, typed.mode);
}

test "the second core's image comes before the debugger flag" {
    const both = try debug_front.wanted(&.{ "ra8_emulator", "fw.elf", "--cpu1", "cpu1.elf", "--debug-script", "s.gdb" }).?;
    try std.testing.expectEqualStrings("cpu1.elf", both.cpu1.?);
    try std.testing.expectEqualStrings("s.gdb", both.mode.script);
    const typed = try debug_front.wanted(&.{ "ra8_emulator", "fw.elf", "--cpu1", "cpu1.elf", "--debug" }).?;
    try std.testing.expectEqualStrings("cpu1.elf", typed.cpu1.?);
}

test "a debugger flag mixed with run flags, or missing its file, is bad usage" {
    try std.testing.expectError(error.BadUsage, debug_front.wanted(&.{ "ra8_emulator", "fw.elf", "--debug-script" }).?);
    try std.testing.expectError(error.BadUsage, debug_front.wanted(&.{ "ra8_emulator", "fw.elf", "--debug", "--ms", "2" }).?);
    try std.testing.expectError(error.BadUsage, debug_front.wanted(&.{ "ra8_emulator", "fw.elf", "--ms", "2", "--debug" }).?);
    try std.testing.expectError(error.BadUsage, debug_front.wanted(&.{ "ra8_emulator", "--debug", "fw.elf" }).?);
    try std.testing.expectError(error.BadUsage, debug_front.wanted(&.{ "ra8_emulator", "fw.elf", "--cpu1", "--debug" }).?);
    try std.testing.expectError(error.BadUsage, debug_front.wanted(&.{ "ra8_emulator", "fw.elf", "--debug", "--cpu1", "c.elf" }).?);
}

test "--gdb takes a port, after the second core's image when there is one" {
    const served = try debug_front.wanted(&.{ "ra8_emulator", "fw.elf", "--gdb", "3333" }).?;
    try std.testing.expectEqual(@as(u16, 3333), served.mode.gdb);
    const both = try debug_front.wanted(&.{ "ra8_emulator", "fw.elf", "--cpu1", "cpu1.elf", "--gdb", "1234" }).?;
    try std.testing.expectEqualStrings("cpu1.elf", both.cpu1.?);
    try std.testing.expectEqual(@as(u16, 1234), both.mode.gdb);
    try std.testing.expectError(error.BadUsage, debug_front.wanted(&.{ "ra8_emulator", "fw.elf", "--gdb" }).?);
    try std.testing.expectError(error.BadUsage, debug_front.wanted(&.{ "ra8_emulator", "fw.elf", "--gdb", "port" }).?);
    try std.testing.expectError(error.BadUsage, debug_front.wanted(&.{ "ra8_emulator", "fw.elf", "--gdb", "70000" }).?);
}

test {
    // tests/all.zig is at its 400-line limit; the Zig front's tests ride here.
    _ = @import("zig/debug_front_test.zig");
}
