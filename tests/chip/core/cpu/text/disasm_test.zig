//! Covers src/chip/core/cpu/text/disasm.zig.
const std = @import("std");
const ra8 = @import("ra8");
const disasm = ra8.chip.core.cpu.decode.text.disasm;
const Instr = ra8.chip.core.cpu.instr.Instr;

test "a decoded instruction with a printer comes back as text" {
    const instr: Instr = .{ .address = 0x0200_0100, .hw1 = 0x1888, .size = 2 };
    try std.testing.expectEqualStrings("adds r0, r1, r2", disasm.one(instr).?.slice());
}

test "an encoding nothing decodes has no text" {
    const instr: Instr = .{ .address = 0x0200_0100, .hw1 = 0xBA80, .size = 2 };
    try std.testing.expect(disasm.one(instr) == null);
}
