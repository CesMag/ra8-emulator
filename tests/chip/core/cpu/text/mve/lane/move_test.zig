//! Covers src/chip/core/cpu/text/mve/lane/move.zig against DDI0553 syntax.
const v81m = @import("../../v81m.zig");

test "single-lane VMOV prints vector and core register forms" {
    try v81m.expectTexts(&.{
        .{ .hw1 = 0xEE63, .hw2 = 0x2B70, .text = "vmov.8 q1[15], r2" },
        .{ .hw1 = 0xEE01, .hw2 = 0x1B10, .text = "vmov.32 q0[2], r1" },
        .{ .hw1 = 0xEE73, .hw2 = 0x1B70, .text = "vmov.s8 r1, q1[15]" },
        .{ .hw1 = 0xEE93, .hw2 = 0x1B70, .text = "vmov.u16 r1, q1[5]" },
        .{ .hw1 = 0xEE3F, .hw2 = 0x1B10, .text = "vmov.32 r1, q7[3]" },
    });
}
