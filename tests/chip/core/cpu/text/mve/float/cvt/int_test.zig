//! Covers MVE integer conversions against DDI0553 C2.4.326.
const v81m = @import("../../../v81m.zig");

test "conversion receives VPT T suffix" {
    try v81m.expectPredicated(.{ .hw1 = 0xFFBB, .hw2 = 0x01C2, .text = "" }, "vcvtnt.u32.f32 q0, q1");
}

test "integer conversion prints direction, width and named rounding" {
    try v81m.expectTexts(&.{
        .{ .hw1 = 0xFFBB, .hw2 = 0x0642, .text = "vcvt.f32.s32 q0, q1" },
        .{ .hw1 = 0xFFBB, .hw2 = 0x06C2, .text = "vcvt.f32.u32 q0, q1" },
        .{ .hw1 = 0xFFBB, .hw2 = 0x0742, .text = "vcvt.s32.f32 q0, q1" },
        .{ .hw1 = 0xFFBB, .hw2 = 0x07C2, .text = "vcvt.u32.f32 q0, q1" },
        .{ .hw1 = 0xFFBB, .hw2 = 0x0042, .text = "vcvta.s32.f32 q0, q1" },
        .{ .hw1 = 0xFFBB, .hw2 = 0x01C2, .text = "vcvtn.u32.f32 q0, q1" },
        .{ .hw1 = 0xFFBB, .hw2 = 0x0242, .text = "vcvtp.s32.f32 q0, q1" },
    });
}
