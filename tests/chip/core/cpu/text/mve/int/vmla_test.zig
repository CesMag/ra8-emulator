//! Covers MVE integer scalar multiply-accumulate against DDI0553 B5.
const v81m = @import("../../v81m.zig");

test "VMLA and VMLAS print integer widths and scalar registers" {
    try v81m.expectTexts(&.{
        .{ .hw1 = 0xEE03, .hw2 = 0x0E42, .text = "vmla.i8 q0, q1, r2" },
        .{ .hw1 = 0xEE13, .hw2 = 0x1E42, .text = "vmlas.i16 q0, q1, r2" },
        .{ .hw1 = 0xEE2F, .hw2 = 0x0E4C, .text = "vmla.i32 q0, q7, ip" },
    });
}
test "VMLA receives VPT T suffix" {
    try v81m.expectPredicated(.{ .hw1 = 0xEE03, .hw2 = 0x0E42, .text = "" }, "vmlat.i8 q0, q1, r2");
}
