//! Covers MVE contiguous load/store text against DDI0553 B5.
const std = @import("std");
const ra8 = @import("ra8");
const Instr = ra8.chip.core.cpu.instr.Instr;
const disasm = ra8.chip.core.cpu.decode.text.disasm;
const v81m = @import("v81m.zig");

test "contiguous memory operations print widths and indexing modes" {
    try v81m.expectTexts(&.{
        .{ .hw1 = 0xED91, .hw2 = 0x1E03, .text = "vldrb.u8 q0, [r1, #3]" },
        .{ .hw1 = 0xED31, .hw2 = 0x5E82, .text = "vldrh.u16 q2, [r1, #-4]!" },
        .{ .hw1 = 0xECB1, .hw2 = 0xFF02, .text = "vldrw.u32 q7, [r1], #8" },
        .{ .hw1 = 0xED21, .hw2 = 0x1F02, .text = "vstrw.32 q0, [r1, #-8]!" },
    });
}
test "contiguous loads receive VPT T suffix" {
    const vpst: Instr = .{ .address = 0x0200_0100, .hw1 = 0xFE71, .hw2 = 0x8F4D, .size = 4 };
    const load: Instr = .{ .address = 0x0200_0104, .hw1 = 0xED91, .hw2 = 0x1E03, .size = 4 };
    var stream: disasm.Stream = .{};
    try std.testing.expectEqualStrings("vpste", stream.format(vpst).?.slice());
    try std.testing.expectEqualStrings("vldrbt.u8 q0, [r1, #3]", stream.format(load).?.slice());
}
