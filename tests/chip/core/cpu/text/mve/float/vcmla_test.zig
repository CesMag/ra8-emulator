//! Covers MVE VCMLA against DDI0553 B5.
const v81m = @import("../../v81m.zig");

test "complex multiply accumulate prints all rotations" {
    try v81m.expectTexts(&.{
        .{ .hw1 = 0xFC32, .hw2 = 0x0844, .text = "vcmla.f32 q0, q1, q2, #0" },
        .{ .hw1 = 0xFCB2, .hw2 = 0x0844, .text = "vcmla.f32 q0, q1, q2, #90" },
        .{ .hw1 = 0xFD32, .hw2 = 0x0844, .text = "vcmla.f32 q0, q1, q2, #180" },
        .{ .hw1 = 0xFDB2, .hw2 = 0x0844, .text = "vcmla.f32 q0, q1, q2, #270" },
    });
}
test "complex multiply accumulate receives VPT T suffix" {
    try v81m.expectPredicated(.{ .hw1 = 0xFC32, .hw2 = 0x0844, .text = "" }, "vcmlat.f32 q0, q1, q2, #0");
}
