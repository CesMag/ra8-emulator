//! Covers MVE VCADD against DDI0553 B5.
const v81m = @import("../../v81m.zig");

test "complex add prints 90 and 270 degree rotations" {
    try v81m.expectTexts(&.{
        .{ .hw1 = 0xFC92, .hw2 = 0x0844, .text = "vcadd.f32 q0, q1, q2, #90" },
        .{ .hw1 = 0xFD92, .hw2 = 0x0844, .text = "vcadd.f32 q0, q1, q2, #270" },
    });
}
test "complex add receives VPT T suffix" {
    try v81m.expectPredicated(.{ .hw1 = 0xFC92, .hw2 = 0x0844, .text = "" }, "vcaddt.f32 q0, q1, q2, #90");
}
