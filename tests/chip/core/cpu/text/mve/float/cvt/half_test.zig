//! Covers MVE F16/F32 conversion against DDI0553 C2.4.327.
const v81m = @import("../../../v81m.zig");

test "conversion receives VPT T suffix" {
    try v81m.expectPredicated(.{ .hw1 = 0xEE3F, .hw2 = 0x0E03, .text = "" }, "vcvtbt.f16.f32 q0, q1");
}

test "VCVTB and VCVTT print narrowing and widening types" {
    try v81m.expectTexts(&.{
        .{ .hw1 = 0xEE3F, .hw2 = 0x0E03, .text = "vcvtb.f16.f32 q0, q1" },
        .{ .hw1 = 0xEE3F, .hw2 = 0x1E03, .text = "vcvtt.f16.f32 q0, q1" },
        .{ .hw1 = 0xFE3F, .hw2 = 0x0E03, .text = "vcvtb.f32.f16 q0, q1" },
        .{ .hw1 = 0xFE3F, .hw2 = 0xFE0D, .text = "vcvtt.f32.f16 q7, q6" },
    });
}
