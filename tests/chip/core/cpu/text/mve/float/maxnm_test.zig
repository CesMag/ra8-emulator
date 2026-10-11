//! Covers MVE vector maxnum/minnum against DDI0553 B5.
const v81m = @import("../../v81m.zig");

test "vector maxnum prints operation and lane type" {
    try v81m.expectTexts(&.{
        .{ .hw1 = 0xFF02, .hw2 = 0x0F54, .text = "vmaxnm.f32 q0, q1, q2" },
        .{ .hw1 = 0xFF22, .hw2 = 0x0F54, .text = "vminnm.f32 q0, q1, q2" },
        .{ .hw1 = 0xFF12, .hw2 = 0x0F54, .text = "vmaxnm.f16 q0, q1, q2" },
    });
}
test "vector maxnum receives VPT T suffix" {
    try v81m.expectPredicated(.{ .hw1 = 0xFF02, .hw2 = 0x0F54, .text = "" }, "vmaxnmt.f32 q0, q1, q2");
}
