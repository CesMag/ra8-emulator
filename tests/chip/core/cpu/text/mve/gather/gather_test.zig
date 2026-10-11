//! Covers MVE register gather/scatter printers against DDI0553 C2.4.366/486.
const std = @import("std");
const ra8 = @import("ra8");
const Instr = ra8.chip.core.cpu.instr.Instr;
const disasm = ra8.chip.core.cpu.decode.text.disasm;
const v81m = @import("../../v81m.zig");

test "gather loads print access type, signedness and scaled offsets" {
    try v81m.expectTexts(&.{
        .{ .hw1 = 0xFC91, .hw2 = 0x0E02, .text = "vldrb.u8 q0, [r1, q1]" },
        .{ .hw1 = 0xFC91, .hw2 = 0x4E97, .text = "vldrh.u16 q2, [r1, q3, uxtw #1]" },
        .{ .hw1 = 0xFC91, .hw2 = 0x0F43, .text = "vldrw.u32 q0, [r1, q1, uxtw #2]" },
    });
}

test "gather receives VPT T suffix" {
    const vpst: Instr = .{ .address = 0x0200_0100, .hw1 = 0xFE71, .hw2 = 0x8F4D, .size = 4 };
    const load: Instr = .{ .address = 0x0200_0104, .hw1 = 0xFC91, .hw2 = 0x0E02, .size = 4 };
    var stream: disasm.Stream = .{};
    try std.testing.expectEqualStrings("vpste", stream.format(vpst).?.slice());
    try std.testing.expectEqualStrings("vldrbt.u8 q0, [r1, q1]", stream.format(load).?.slice());
}
