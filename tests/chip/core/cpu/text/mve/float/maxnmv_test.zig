//! Covers MVE scalar maxnum/minnum reductions against DDI0553 B5.
const v81m = @import("../../v81m.zig");

test "maxnm reductions print accumulator and absolute variants" {
    try v81m.expectTexts(&.{
        .{ .hw1 = 0xEEEE, .hw2 = 0x0F02, .text = "vmaxnmv.f32 r0, q1" },
        .{ .hw1 = 0xEEEE, .hw2 = 0x0F82, .text = "vminnmv.f32 r0, q1" },
        .{ .hw1 = 0xEEEC, .hw2 = 0x0F02, .text = "vmaxnmav.f32 r0, q1" },
    });
}
test "maxnm reduction receives VPT T suffix" {
    try v81m.expectPredicated(.{ .hw1 = 0xEEEE, .hw2 = 0x0F02, .text = "" }, "vmaxnmvt.f32 r0, q1");
}
