//! Covers MVE VCMUL against DDI0553 B5.
const v81m = @import("../../v81m.zig");

test "complex multiply prints all rotations" {
    try v81m.expectTexts(&.{
        .{ .hw1 = 0xFE32, .hw2 = 0x0E04, .text = "vcmul.f32 q0, q1, q2, #0" },
        .{ .hw1 = 0xFE32, .hw2 = 0x0E05, .text = "vcmul.f32 q0, q1, q2, #90" },
        .{ .hw1 = 0xFE32, .hw2 = 0x1E04, .text = "vcmul.f32 q0, q1, q2, #180" },
        .{ .hw1 = 0xFE32, .hw2 = 0x1E05, .text = "vcmul.f32 q0, q1, q2, #270" },
    });
}
test "complex multiply receives VPT T suffix" {
    try v81m.expectPredicated(.{ .hw1 = 0xFE32, .hw2 = 0x0E04, .text = "" }, "vcmult.f32 q0, q1, q2, #0");
}
