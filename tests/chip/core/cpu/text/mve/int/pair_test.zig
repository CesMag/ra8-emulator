//! Covers src/chip/core/cpu/text/mve/int/pair.zig against DDI0553 syntax.
const std = @import("std");
const ra8 = @import("ra8");
const Instr = ra8.chip.core.cpu.instr.Instr;
const disasm = ra8.chip.core.cpu.decode.text.disasm;
const v81m = @import("../../v81m.zig");

test "saturating and pairwise integer operations print mnemonic, type, and Q registers" {
    try v81m.expectTexts(&.{
        .{ .hw1 = 0xEF02, .hw2 = 0x0054, .text = "vqadd.s8 q0, q1, q2" },
        .{ .hw1 = 0xFF02, .hw2 = 0x0254, .text = "vqsub.u8 q0, q1, q2" },
        .{ .hw1 = 0xFF02, .hw2 = 0x0044, .text = "vhadd.u8 q0, q1, q2" },
        .{ .hw1 = 0xFF02, .hw2 = 0x0144, .text = "vrhadd.u8 q0, q1, q2" },
        .{ .hw1 = 0xEF02, .hw2 = 0x0244, .text = "vhsub.s8 q0, q1, q2" },
        .{ .hw1 = 0xEF02, .hw2 = 0x0644, .text = "vmax.s8 q0, q1, q2" },
        .{ .hw1 = 0xFF02, .hw2 = 0x0654, .text = "vmin.u8 q0, q1, q2" },
        .{ .hw1 = 0xEF02, .hw2 = 0x0744, .text = "vabd.s8 q0, q1, q2" },
    });
}

test "pairwise MVE instructions receive the VPT T/E suffix" {
    const vpst: Instr = .{ .address = 0x0200_0100, .hw1 = 0xFE71, .hw2 = 0x8F4D, .size = 4 };
    const add: Instr = .{ .address = 0x0200_0104, .hw1 = 0xEF02, .hw2 = 0x0054, .size = 4 };
    const sub: Instr = .{ .address = 0x0200_0108, .hw1 = 0xFF02, .hw2 = 0x0254, .size = 4 };
    var stream: disasm.Stream = .{};
    try std.testing.expectEqualStrings("vpste", stream.format(vpst).?.slice());
    try std.testing.expectEqualStrings("vqaddt.s8 q0, q1, q2", stream.format(add).?.slice());
    try std.testing.expectEqualStrings("vqsube.u8 q0, q1, q2", stream.format(sub).?.slice());
}
