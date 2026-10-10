//! Covers src/chip/core/cpu/text/mve_vdup.zig against DDI0553 syntax.
const std = @import("std");
const ra8 = @import("ra8");
const Instr = ra8.chip.core.cpu.instr.Instr;
const disasm = ra8.chip.core.cpu.decode.text.disasm;
const v81m = @import("v81m.zig");

test "VDUP prints its element width, vector register, and scalar register" {
    try v81m.expectTexts(&.{
        .{ .hw1 = 0xEEA0, .hw2 = 0x1B10, .text = "vdup.32 q0, r1" },
        .{ .hw1 = 0xEEA0, .hw2 = 0x1B30, .text = "vdup.16 q0, r1" },
        .{ .hw1 = 0xEEE4, .hw2 = 0x1B10, .text = "vdup.8 q2, r1" },
        .{ .hw1 = 0xEEAE, .hw2 = 0xCB10, .text = "vdup.32 q7, ip" },
    });
}

test "VDUP receives the T suffix in a VPST block" {
    const vpst: Instr = .{ .address = 0x0200_0100, .hw1 = 0xFE71, .hw2 = 0x0F4D, .size = 4 };
    const vdup: Instr = .{ .address = 0x0200_0104, .hw1 = 0xEEA0, .hw2 = 0x1B10, .size = 4 };
    var stream: disasm.Stream = .{};
    try std.testing.expectEqualStrings("vpst", stream.format(vpst).?.slice());
    try std.testing.expectEqualStrings("vdupt.32 q0, r1", stream.format(vdup).?.slice());
}
