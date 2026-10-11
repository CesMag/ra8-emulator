//! Covers MVE absolute maxnum/minnum accumulation against DDI0553 B5.
const v81m = @import("../../v81m.zig");

test "maxnma prints operation and width" {
    try v81m.expectTexts(&.{
        .{ .hw1 = 0xEE3F, .hw2 = 0x0E81, .text = "vmaxnma.f32 q0, q0" },
        .{ .hw1 = 0xEE3F, .hw2 = 0x1E81, .text = "vminnma.f32 q0, q0" },
        .{ .hw1 = 0xFE3F, .hw2 = 0x0E81, .text = "vmaxnma.f16 q0, q0" },
    });
}
test "maxnma receives VPT T suffix" {
    try v81m.expectPredicated(.{ .hw1 = 0xEE3F, .hw2 = 0x0E81, .text = "" }, "vmaxnmat.f32 q0, q0");
}
