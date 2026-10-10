//! Covers src/chip/core/cpu/text/mve_vmaxv.zig against DDI0553 syntax.
const std = @import("std");
const ra8 = @import("ra8");
const Instr = ra8.chip.core.cpu.instr.Instr;
const disasm = ra8.chip.core.cpu.decode.text.disasm;
const v81m = @import("v81m.zig");

test "VMAXV, VMINV, VMAXAV and VMINAV print signedness and widths" {
    try v81m.expectTexts(&.{
        .{ .hw1 = 0xEEE2, .hw2 = 0x1F00, .text = "vmaxv.s8 r1, q0" },
        .{ .hw1 = 0xFEEA, .hw2 = 0xCF8E, .text = "vminv.u32 ip, q7" },
        .{ .hw1 = 0xEEE0, .hw2 = 0x1F00, .text = "vmaxav.s8 r1, q0" },
        .{ .hw1 = 0xEEE4, .hw2 = 0x2F86, .text = "vminav.s16 r2, q3" },
    });
}

test "VMAXV gets the T/E decorator inside a VPST block" {
    const vpst: Instr = .{ .address = 0x0200_0100, .hw1 = 0xFE71, .hw2 = 0x8F4D, .size = 4 };
    const maximum: Instr = .{ .address = 0x0200_0104, .hw1 = 0xEEE2, .hw2 = 0x1F00, .size = 4 };
    const minimum: Instr = .{ .address = 0x0200_0108, .hw1 = 0xFEE2, .hw2 = 0x1F80, .size = 4 };
    var stream: disasm.Stream = .{};
    try std.testing.expectEqualStrings("vpste", stream.format(vpst).?.slice());
    try std.testing.expectEqualStrings("vmaxvt.s8 r1, q0", stream.format(maximum).?.slice());
    try std.testing.expectEqualStrings("vminve.u8 r1, q0", stream.format(minimum).?.slice());
}
