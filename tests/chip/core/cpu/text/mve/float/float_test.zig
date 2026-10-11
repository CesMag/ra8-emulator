//! Covers src/chip/core/cpu/text/mve/float/float.zig against DDI0553 B5 syntax.
const std = @import("std");
const ra8 = @import("ra8");
const Instr = ra8.chip.core.cpu.instr.Instr;
const disasm = ra8.chip.core.cpu.decode.text.disasm;
const v81m = @import("../../v81m.zig");

test "MVE floating arithmetic prints operation and lane type" {
    try v81m.expectTexts(&.{
        .{ .hw1 = 0xEF02, .hw2 = 0x0D44, .text = "vadd.f32 q0, q1, q2" },
        .{ .hw1 = 0xEF22, .hw2 = 0x0D44, .text = "vsub.f32 q0, q1, q2" },
        .{ .hw1 = 0xFF02, .hw2 = 0x0D54, .text = "vmul.f32 q0, q1, q2" },
        .{ .hw1 = 0xFF22, .hw2 = 0x0D44, .text = "vabd.f32 q0, q1, q2" },
        .{ .hw1 = 0xEF12, .hw2 = 0x0D44, .text = "vadd.f16 q0, q1, q2" },
    });
}

test "floating operations receive VPT T/E suffixes" {
    const vpst: Instr = .{ .address = 0x0200_0100, .hw1 = 0xFE71, .hw2 = 0x8F4D, .size = 4 };
    const add: Instr = .{ .address = 0x0200_0104, .hw1 = 0xEF02, .hw2 = 0x0D44, .size = 4 };
    const sub: Instr = .{ .address = 0x0200_0108, .hw1 = 0xEF22, .hw2 = 0x0D44, .size = 4 };
    var stream: disasm.Stream = .{};
    try std.testing.expectEqualStrings("vpste", stream.format(vpst).?.slice());
    try std.testing.expectEqualStrings("vaddt.f32 q0, q1, q2", stream.format(add).?.slice());
    try std.testing.expectEqualStrings("vsube.f32 q0, q1, q2", stream.format(sub).?.slice());
}
