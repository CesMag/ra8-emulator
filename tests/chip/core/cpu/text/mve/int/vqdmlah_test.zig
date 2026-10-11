//! Covers MVE doubling multiply-accumulate against DDI0553 B5.
const v81m = @import("../../v81m.zig");

test "VQDMLAH family prints scalar-add and rounding variants" {
    try v81m.expectTexts(&.{
        .{ .hw1 = 0xEE02, .hw2 = 0x0E62, .text = "vqdmlah.s8 q0, q1, r2" },
        .{ .hw1 = 0xEE12, .hw2 = 0x0E42, .text = "vqrdmlah.s16 q0, q1, r2" },
        .{ .hw1 = 0xEE22, .hw2 = 0x1E62, .text = "vqdmlash.s32 q0, q1, r2" },
        .{ .hw1 = 0xEE0C, .hw2 = 0xFE4C, .text = "vqrdmlash.s8 q7, q6, ip" },
    });
}
test "VQDMLAH receives VPT T suffix" {
    try v81m.expectPredicated(.{ .hw1 = 0xEE02, .hw2 = 0x0E62, .text = "" }, "vqdmlaht.s8 q0, q1, r2");
}
