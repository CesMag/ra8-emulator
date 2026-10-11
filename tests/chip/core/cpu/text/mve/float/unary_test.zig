//! Covers MVE VABS/VNEG against DDI0553 B5.
const v81m = @import("../../v81m.zig");

test "floating unary operations print F16/F32 widths" {
    try v81m.expectTexts(&.{
        .{ .hw1 = 0xFFB9, .hw2 = 0x0742, .text = "vabs.f32 q0, q1" },
        .{ .hw1 = 0xFFB9, .hw2 = 0x07C2, .text = "vneg.f32 q0, q1" },
        .{ .hw1 = 0xFFB5, .hw2 = 0x0742, .text = "vabs.f16 q0, q1" },
    });
}
test "floating unary receives VPT T suffix" {
    try v81m.expectPredicated(.{ .hw1 = 0xFFB9, .hw2 = 0x0742, .text = "" }, "vabst.f32 q0, q1");
}
