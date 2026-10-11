//! Covers MVE VFMA/VFMS against DDI0553 B5.
const v81m = @import("../../v81m.zig");

test "fused arithmetic prints operation and F16/F32 width" {
    try v81m.expectTexts(&.{
        .{ .hw1 = 0xEF02, .hw2 = 0x0C54, .text = "vfma.f32 q0, q1, q2" },
        .{ .hw1 = 0xEF22, .hw2 = 0x0C54, .text = "vfms.f32 q0, q1, q2" },
        .{ .hw1 = 0xEF38, .hw2 = 0x6C52, .text = "vfms.f16 q3, q4, q1" },
    });
}
test "fused arithmetic receives VPT T suffix" {
    try v81m.expectPredicated(.{ .hw1 = 0xEF02, .hw2 = 0x0C54, .text = "" }, "vfmat.f32 q0, q1, q2");
}
