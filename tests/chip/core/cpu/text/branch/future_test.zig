//! Covers src/chip/core/cpu/text/branch/future.zig against the Arm ARM syntax.
//! Every case sits at 0x0200_0100, so the next instruction is 0x0200_0104.
const v81m = @import("../v81m.zig");

test "BF and BFL print the branch point and the target" {
    try v81m.expectTexts(&.{
        .{ .hw1 = 0xF140, .hw2 = 0xE011, .text = "bf #0x2000108, #0x2000124" },
        .{ .hw1 = 0xF15F, .hw2 = 0xE7F9, .text = "bf #0x2000108, #0x20000f4" },
        .{ .hw1 = 0xF180, .hw2 = 0xC021, .text = "bfl #0x200010a, #0x2000144" },
    });
}

test "BFX and BFLX print the branch point and the register" {
    try v81m.expectTexts(&.{
        .{ .hw1 = 0xF0E3, .hw2 = 0xE001, .text = "bfx #0x2000106, r3" },
        .{ .hw1 = 0xF0F4, .hw2 = 0xE001, .text = "bflx #0x2000106, r4" },
    });
}

test "BFCSEL prints the else address from T and the condition" {
    try v81m.expectTexts(&.{
        .{ .hw1 = 0xF102, .hw2 = 0xE011, .text = "bfcsel #0x2000108, #0x2000124, #0x200010c, eq" },
        .{ .hw1 = 0xF104, .hw2 = 0xE011, .text = "bfcsel #0x2000108, #0x2000124, #0x200010a, ne" },
    });
}
