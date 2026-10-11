//! Covers src/chip/core/cpu/text/mve/int/mulh.zig against DDI0553 B5 syntax.
const std = @import("std");
const ra8 = @import("ra8");
const Instr = ra8.chip.core.cpu.instr.Instr;
const disasm = ra8.chip.core.cpu.decode.text.disasm;
const v81m = @import("../../v81m.zig");

test "MVE multiply high prints signedness, rounding and width" {
    try v81m.expectTexts(&.{
        .{ .hw1 = 0xEE03, .hw2 = 0x0E05, .text = "vmulh.s8 q0, q1, q2" },
        .{ .hw1 = 0xFE03, .hw2 = 0x0E05, .text = "vmulh.u8 q0, q1, q2" },
        .{ .hw1 = 0xFE03, .hw2 = 0x1E05, .text = "vrmulh.u8 q0, q1, q2" },
        .{ .hw1 = 0xEF12, .hw2 = 0x0B44, .text = "vqdmulh.s16 q0, q1, q2" },
        .{ .hw1 = 0xFF12, .hw2 = 0x0B44, .text = "vqrdmulh.s16 q0, q1, q2" },
    });
}

test "multiply high receives VPT T suffix" {
    const vpst: Instr = .{ .address = 0x0200_0100, .hw1 = 0xFE71, .hw2 = 0x8F4D, .size = 4 };
    const mul: Instr = .{ .address = 0x0200_0104, .hw1 = 0xEE03, .hw2 = 0x0E05, .size = 4 };
    var stream: disasm.Stream = .{};
    try std.testing.expectEqualStrings("vpste", stream.format(vpst).?.slice());
    try std.testing.expectEqualStrings("vmulht.s8 q0, q1, q2", stream.format(mul).?.slice());
}
