//! Covers MVE widening load/narrowing store text against DDI0553 B5.
const v81m = @import("../../v81m.zig");

test "wide memory operations print transfer and lane types" {
    try v81m.expectTexts(&.{
        .{ .hw1 = 0xED91, .hw2 = 0x0E83, .text = "vldrb.s16 q0, [r1, #3]" },
        .{ .hw1 = 0xFD32, .hw2 = 0x2E82, .text = "vldrb.u16 q1, [r2, #-2]!" },
        .{ .hw1 = 0xECB3, .hw2 = 0x4F04, .text = "vldrb.s32 q2, [r3], #4" },
        .{ .hw1 = 0xED99, .hw2 = 0x8F02, .text = "vldrh.s32 q4, [r1, #4]" },
        .{ .hw1 = 0xED21, .hw2 = 0x2F01, .text = "vstrb.32 q1, [r1, #-1]!" },
    });
}
