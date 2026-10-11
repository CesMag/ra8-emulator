//! Covers MVE scalar floating arithmetic against DDI0553 B5.
const v81m = @import("../../v81m.zig");

test "scalar floating arithmetic prints operation, Q source and Rm" {
    try v81m.expectTexts(&.{
        .{ .hw1 = 0xEE32, .hw2 = 0x0F42, .text = "vadd.f32 q0, q1, r2" },
        .{ .hw1 = 0xEE32, .hw2 = 0x1F42, .text = "vsub.f32 q0, q1, r2" },
        .{ .hw1 = 0xEE33, .hw2 = 0x0E62, .text = "vmul.f32 q0, q1, r2" },
        .{ .hw1 = 0xEE33, .hw2 = 0x0E42, .text = "vfma.f32 q0, q1, r2" },
        .{ .hw1 = 0xEE33, .hw2 = 0x1E42, .text = "vfmas.f32 q0, q1, r2" },
    });
}
test "scalar floating arithmetic receives VPT T suffix" {
    try v81m.expectPredicated(.{ .hw1 = 0xEE32, .hw2 = 0x0F42, .text = "" }, "vaddt.f32 q0, q1, r2");
}
