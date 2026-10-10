//! The layout of a register dump.
const std = @import("std");
const ra8 = @import("ra8");
const registers = ra8.session.registers;

test "the argument registers lead the dump" {
    try std.testing.expectEqualStrings("r0", registers.dumped[0].name);
    try std.testing.expectEqualStrings("r1", registers.dumped[1].name);
    try std.testing.expectEqualStrings("r2", registers.dumped[2].name);
    try std.testing.expectEqualStrings("r3", registers.dumped[3].name);
}

test "the dump ends on the program counter" {
    const last = registers.dumped[registers.dumped.len - 1];
    try std.testing.expectEqualStrings("pc", last.name);
    try std.testing.expectEqual(ra8.chip.core.cpu.cortex.Cortex.pc, last.which);
}

test "a line ends every fourth register" {
    try std.testing.expect(!registers.endsLine(0));
    try std.testing.expect(!registers.endsLine(2));
    try std.testing.expect(registers.endsLine(3));
    try std.testing.expect(registers.endsLine(7));
}

test "the last register ends its line whether or not it filled one" {
    try std.testing.expect(registers.endsLine(registers.dumped.len - 1));
}

test "stack words step one word at a time" {
    try std.testing.expectEqual(@as(u32, 0x2008_0000), registers.stackWord(0x2008_0000, 0));
    try std.testing.expectEqual(@as(u32, 0x2008_0004), registers.stackWord(0x2008_0000, 1));
    try std.testing.expectEqual(@as(u32, 0x2008_000C), registers.stackWord(0x2008_0000, 3));
}

test "a stack pointer at the top of the address space wraps rather than trapping" {
    try std.testing.expectEqual(@as(u32, 0), registers.stackWord(0xFFFF_FFFC, 1));
}

test "four registers to a line, and four stack words" {
    try std.testing.expectEqual(@as(usize, 4), registers.limits.per_line);
    try std.testing.expectEqual(@as(usize, 4), registers.limits.stack_words);
}
