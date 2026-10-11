//! Covers MVE VRINT modes against DDI0553 B5.
const v81m = @import("../../v81m.zig");

test "VRINT prints each supported rounding mode" {
    try v81m.expectTexts(&.{
        .{ .hw1 = 0xFFBA, .hw2 = 0x0442, .text = "vrintn.f32 q0, q1" },
        .{ .hw1 = 0xFFBA, .hw2 = 0x04C2, .text = "vrintx.f32 q0, q1" },
        .{ .hw1 = 0xFFBA, .hw2 = 0x0542, .text = "vrinta.f32 q0, q1" },
        .{ .hw1 = 0xFFBA, .hw2 = 0x05C2, .text = "vrintz.f32 q0, q1" },
        .{ .hw1 = 0xFFBA, .hw2 = 0x06C2, .text = "vrintm.f32 q0, q1" },
        .{ .hw1 = 0xFFBA, .hw2 = 0x07C2, .text = "vrintp.f32 q0, q1" },
    });
}
test "VRINT receives VPT T suffix" {
    try v81m.expectPredicated(.{ .hw1 = 0xFFBA, .hw2 = 0x0442, .text = "" }, "vrintnt.f32 q0, q1");
}
