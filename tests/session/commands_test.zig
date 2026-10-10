//! The command language, one line at a time.
const std = @import("std");
const ra8 = @import("ra8");

const commands = ra8.session.commands;
const Command = commands.Command;

fn expectParsed(expected: Command, line: []const u8) !void {
    const got = (try commands.parse(line)) orelse return error.TestExpectedCommand;
    try std.testing.expectEqualDeep(expected, got);
}

test "a blank line and a comment are nothing to do" {
    try std.testing.expectEqual(@as(?Command, null), try commands.parse(""));
    try std.testing.expectEqual(@as(?Command, null), try commands.parse("   \t\r\n"));
    try std.testing.expectEqual(@as(?Command, null), try commands.parse("# set up the read"));
}

test "a break takes a place and an optional arrival" {
    try expectParsed(.{ .brk = .{ .place = "target" } }, "break target");
    try expectParsed(.{ .brk = .{ .place = "target+4", .arrival = 3 } }, "b target+4 3");
    try expectParsed(.{ .tbreak = .{ .place = "0x22000008", .arrival = 16 } }, "tbreak 0x22000008 0x10");
}

test "a trailing comment and stray spaces do not reach the arguments" {
    try expectParsed(.{ .brk = .{ .place = "f_read", .arrival = 10 } }, "  break   f_read\t10   # the tenth read\r");
}

test "the three watches differ only in what they wait for" {
    try expectParsed(.{ .watch = .{ .place = "counter", .kind = .write } }, "watch counter");
    try expectParsed(.{ .watch = .{ .place = "@s_open+0x40", .kind = .read } }, "rwatch @s_open+0x40");
    try expectParsed(.{ .watch = .{ .place = "0x22000054", .kind = .access } }, "awatch 0x22000054");
}

test "the moving commands take no arguments, under gdb's names and short forms" {
    try expectParsed(.run, "run");
    try expectParsed(.cont, "c");
    try expectParsed(.step, "stepi");
    try expectParsed(.step, "s");
    try expectParsed(.next, "ni");
    try expectParsed(.finish, "finish");
    try expectParsed(.backtrace, "bt");
    try expectParsed(.quit, "q");
}

test "registers are asked for as gdb asks" {
    try expectParsed(.registers, "info registers");
    try expectParsed(.registers, "i r");
    try expectParsed(.registers, "regs");
    try std.testing.expectError(error.UnknownCommand, commands.parse("info frogs"));
}

test "memory and disassembly default their counts" {
    try expectParsed(.{ .examine = .{ .place = "counter" } }, "x counter");
    try expectParsed(.{ .examine = .{ .place = "counter", .words = 8 } }, "x counter 8");
    try expectParsed(.{ .print = "counter" }, "p counter");
    try expectParsed(.{ .disassemble = .{} }, "disas");
    try expectParsed(.{ .disassemble = .{ .place = "target", .count = 5 } }, "disassemble target 5");
}

test "delete and core take numbers, and core only names a CPU that exists" {
    try expectParsed(.{ .delete = 2 }, "delete 2");
    try expectParsed(.{ .core = 1 }, "core 1");
    try std.testing.expectError(error.BadCore, commands.parse("core 2"));
    try std.testing.expectError(error.BadCore, commands.parse("core one"));
}

test "a bad line says what was wrong with it" {
    try std.testing.expectError(error.UnknownCommand, commands.parse("jump 0x0"));
    try std.testing.expectError(error.MissingArgument, commands.parse("break"));
    try std.testing.expectError(error.MissingArgument, commands.parse("watch # nothing"));
    try std.testing.expectError(error.ExtraArgument, commands.parse("step 4"));
    try std.testing.expectError(error.ExtraArgument, commands.parse("break target 2 3"));
    try std.testing.expectError(error.BadNumber, commands.parse("break target twice"));
    try std.testing.expectError(error.BadNumber, commands.parse("break target 0"));
    try std.testing.expectError(error.BadNumber, commands.parse("delete one"));
}

test "halting takes on or off" {
    try expectParsed(.{ .halting = false }, "halting off");
    try expectParsed(.{ .halting = true }, "halting on");
    try std.testing.expectError(error.BadSwitch, commands.parse("halting maybe"));
    try std.testing.expectError(error.MissingArgument, commands.parse("halting"));
}

test "breaks and watches are listed as gdb asks" {
    try expectParsed(.breakpoints, "info breakpoints");
    try expectParsed(.breakpoints, "i b");
    try expectParsed(.breakpoints, "info break");
}

test "plug and unplug keep their part and endpoint as written" {
    const plugged = (try commands.parse("plug max17048@i2c:riic@0x36")).?;
    try std.testing.expectEqualStrings("max17048@i2c:riic@0x36", plugged.plug);
    const unplugged = (try commands.parse("unplug uart:sci3  # the modem")).?;
    try std.testing.expectEqualStrings("uart:sci3", unplugged.unplug);
    try std.testing.expectError(error.MissingArgument, commands.parse("plug"));
    try std.testing.expectError(error.ExtraArgument, commands.parse("unplug uart:sci3 now"));
}

test "speed takes a factor and leaves the range to the session" {
    try std.testing.expectEqual(@as(?f64, 0.25), (try commands.parse("speed 0.25")).?.speed);
    try std.testing.expectEqual(@as(?f64, 5), (try commands.parse("speed 5  # five times")).?.speed);
    try std.testing.expectEqual(@as(?f64, null), (try commands.parse("speed max")).?.speed);
    try std.testing.expectError(commands.Error.BadNumber, commands.parse("speed maximum"));
    try std.testing.expectError(commands.Error.BadNumber, commands.parse("speed fast"));
    try std.testing.expectError(commands.Error.MissingArgument, commands.parse("speed"));
}
