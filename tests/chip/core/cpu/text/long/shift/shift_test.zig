//! Covers the four long-shift printers in src/chip/core/cpu/text/ against the
//! Arm ARM syntax: long_shift, long_shift_reg, long_shift_sat and
//! long_shift_sat64.
const v81m = @import("../../v81m.zig");

test "LSLL, LSRL and ASRL by an immediate, an encoded 0 being 32" {
    try v81m.expectTexts(&.{
        .{ .hw1 = 0xEA50, .hw2 = 0x01CF, .text = "lsll r0, r1, #3" },
        .{ .hw1 = 0xEA52, .hw2 = 0x031F, .text = "lsrl r2, r3, #0x20" },
        .{ .hw1 = 0xEA54, .hw2 = 0x552F, .text = "asrl r4, r5, #0x14" },
    });
}

test "LSLL and ASRL by a register" {
    try v81m.expectTexts(&.{
        .{ .hw1 = 0xEA50, .hw2 = 0x210D, .text = "lsll r0, r1, r2" },
        .{ .hw1 = 0xEA54, .hw2 = 0x652D, .text = "asrl r4, r5, r6" },
    });
}

test "the single-register saturating and rounding shifts" {
    try v81m.expectTexts(&.{
        .{ .hw1 = 0xEA50, .hw2 = 0x0F4F, .text = "uqshl r0, #1" },
        .{ .hw1 = 0xEA53, .hw2 = 0x0F1F, .text = "urshr r3, #0x20" },
        .{ .hw1 = 0xEA5C, .hw2 = 0x1F6F, .text = "srshr ip, #5" },
        .{ .hw1 = 0xEA51, .hw2 = 0x7FFF, .text = "sqshl r1, #0x1f" },
        .{ .hw1 = 0xEA50, .hw2 = 0x1F0D, .text = "uqrshl r0, r1" },
        .{ .hw1 = 0xEA52, .hw2 = 0x3F2D, .text = "sqrshr r2, r3" },
    });
}

test "the 64-bit saturating shifts, the register forms with their width" {
    try v81m.expectTexts(&.{
        .{ .hw1 = 0xEA51, .hw2 = 0x01CF, .text = "uqshll r0, r1, #3" },
        .{ .hw1 = 0xEA53, .hw2 = 0x033F, .text = "sqshll r2, r3, #0x20" },
        .{ .hw1 = 0xEA51, .hw2 = 0x210D, .text = "uqrshll r0, r1, #0x40, r2" },
        .{ .hw1 = 0xEA55, .hw2 = 0x65AD, .text = "sqrshrl r4, r5, #0x30, r6" },
    });
}
