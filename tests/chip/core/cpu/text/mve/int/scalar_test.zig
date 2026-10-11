//! Covers MVE integer vector-by-scalar operations against DDI0553 B5.
const v81m = @import("../../v81m.zig");

test "integer scalar forms print their lane type and operation" {
    try v81m.expectTexts(&.{
        .{ .hw1 = 0xEE13, .hw2 = 0x0F42, .text = "vadd.i16 q0, q1, r2" },
        .{ .hw1 = 0xEE23, .hw2 = 0x1F42, .text = "vsub.i32 q0, q1, r2" },
        .{ .hw1 = 0xEE23, .hw2 = 0x1E62, .text = "vmul.i32 q0, q1, r2" },
        .{ .hw1 = 0xFE22, .hw2 = 0x0F62, .text = "vqadd.u32 q0, q1, r2" },
        .{ .hw1 = 0xEE02, .hw2 = 0x1F62, .text = "vqsub.s8 q0, q1, r2" },
        .{ .hw1 = 0xFE02, .hw2 = 0x0F42, .text = "vhadd.u8 q0, q1, r2" },
        .{ .hw1 = 0xEE12, .hw2 = 0x1F42, .text = "vhsub.s16 q0, q1, r2" },
        .{ .hw1 = 0xEE13, .hw2 = 0x0E62, .text = "vqdmulh.s16 q0, q1, r2" },
        .{ .hw1 = 0xFE13, .hw2 = 0x0E62, .text = "vqrdmulh.s16 q0, q1, r2" },
        .{ .hw1 = 0xFE03, .hw2 = 0x1E62, .text = "vbrsr.u8 q0, q1, r2" },
    });
}
test "integer scalar forms receive VPT T suffix" {
    try v81m.expectPredicated(.{ .hw1 = 0xEE13, .hw2 = 0x0F42, .text = "" }, "vaddt.i16 q0, q1, r2");
}
