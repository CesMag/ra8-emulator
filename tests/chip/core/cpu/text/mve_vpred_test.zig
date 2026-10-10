//! Covers src/chip/core/cpu/text/mve_vpred.zig against DDI0553 syntax.
const std = @import("std");
const ra8 = @import("ra8");
const Instr = ra8.chip.core.cpu.instr.Instr;
const disasm = ra8.chip.core.cpu.decode.text.disasm;
const v81m = @import("v81m.zig");

test "VPNOT and VPSEL use the architectural UAL syntax" {
    try v81m.expectTexts(&.{
        .{ .hw1 = 0xFE31, .hw2 = 0x0F4D, .text = "vpnot" },
        .{ .hw1 = 0xFE33, .hw2 = 0x0F05, .text = "vpsel q0, q1, q2" },
        .{ .hw1 = 0xFE3F, .hw2 = 0xEF01, .text = "vpsel q7, q7, q0" },
    });
    const hit = ra8.chip.core.cpu.decode.decode(.{
        .address = 0x0200_0100,
        .hw1 = 0xFE33,
        .hw2 = 0x0F05,
        .size = 4,
    }) orelse return error.NotDecoded;
    try std.testing.expectEqualStrings("mve_vpred", hit.group);
}

test "VPSEL receives the T or E suffix from the surrounding VPT block" {
    const vpst: Instr = .{ .address = 0x0200_0100, .hw1 = 0xFE71, .hw2 = 0x8F4D, .size = 4 };
    const select_t: Instr = .{ .address = 0x0200_0104, .hw1 = 0xFE33, .hw2 = 0x0F05, .size = 4 };
    const select_e: Instr = .{ .address = 0x0200_0108, .hw1 = 0xFE33, .hw2 = 0x0F05, .size = 4 };
    var stream: disasm.Stream = .{};
    try std.testing.expectEqualStrings("vpste", stream.format(vpst).?.slice());
    try std.testing.expectEqualStrings("vpselt q0, q1, q2", stream.format(select_t).?.slice());
    try std.testing.expectEqualStrings("vpsele q0, q1, q2", stream.format(select_e).?.slice());
}
