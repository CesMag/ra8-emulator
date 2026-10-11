//! Covers src/chip/core/cpu/text/mve/vctp.zig against DDI0553 syntax.
const v81m = @import("../v81m.zig");

test "VCTP prints each lane width and its source register" {
    try v81m.expectTexts(&.{
        .{ .hw1 = 0xF000, .hw2 = 0xE801, .text = "vctp.8 r0" },
        .{ .hw1 = 0xF013, .hw2 = 0xE801, .text = "vctp.16 r3" },
        .{ .hw1 = 0xF02C, .hw2 = 0xE801, .text = "vctp.32 ip" },
        .{ .hw1 = 0xF031, .hw2 = 0xE801, .text = "vctp.64 r1" },
    });
}
