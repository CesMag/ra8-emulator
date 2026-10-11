//! Covers MVE fixed conversions against DDI0553 C2.4.325.
const v81m = @import("../../../v81m.zig");

test "conversion receives VPT T suffix" {
    try v81m.expectPredicated(.{ .hw1 = 0xEFBF, .hw2 = 0x0E52, .text = "" }, "vcvtt.f32.s32 q0, q1, #1");
}

test "fixed conversion prints direction, signedness, width and fraction bits" {
    try v81m.expectTexts(&.{
        .{ .hw1 = 0xEFBF, .hw2 = 0x0E52, .text = "vcvt.f32.s32 q0, q1, #1" },
        .{ .hw1 = 0xEFB0, .hw2 = 0x0F52, .text = "vcvt.s32.f32 q0, q1, #16" },
        .{ .hw1 = 0xFFBD, .hw2 = 0xEF5C, .text = "vcvt.u32.f32 q7, q6, #3" },
        .{ .hw1 = 0xEFBF, .hw2 = 0x0C52, .text = "vcvt.f16.s16 q0, q1, #1" },
        .{ .hw1 = 0xEFB8, .hw2 = 0x4D58, .text = "vcvt.s16.f16 q2, q4, #8" },
        .{ .hw1 = 0xFFBE, .hw2 = 0x0D52, .text = "vcvt.u16.f16 q0, q1, #2" },
    });
}
