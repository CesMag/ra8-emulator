//! Covers src/chip/core/cpu/text/mve_int_shift.zig against DDI0553 B5 syntax.
const std = @import("std");
const ra8 = @import("ra8");
const Instr = ra8.chip.core.cpu.instr.Instr;
const disasm = ra8.chip.core.cpu.decode.text.disasm;
const v81m = @import("v81m.zig");

test "MVE register shifts print mode, signedness and source order" {
    try v81m.expectTexts(&.{
        .{ .hw1 = 0xEF04, .hw2 = 0x0442, .text = "vshl.s8 q0, q1, q2" },
        .{ .hw1 = 0xEF04, .hw2 = 0x0542, .text = "vrshl.s8 q0, q1, q2" },
        .{ .hw1 = 0xFF04, .hw2 = 0x0452, .text = "vqshl.u8 q0, q1, q2" },
        .{ .hw1 = 0xEF14, .hw2 = 0x0552, .text = "vqrshl.s16 q0, q1, q2" },
    });
}

test "register shift receives VPT T suffix" {
    const vpst: Instr = .{ .address = 0x0200_0100, .hw1 = 0xFE71, .hw2 = 0x8F4D, .size = 4 };
    const shift: Instr = .{ .address = 0x0200_0104, .hw1 = 0xEF04, .hw2 = 0x0442, .size = 4 };
    var stream: disasm.Stream = .{};
    try std.testing.expectEqualStrings("vpste", stream.format(vpst).?.slice());
    try std.testing.expectEqualStrings("vshlt.s8 q0, q1, q2", stream.format(shift).?.slice());
}
