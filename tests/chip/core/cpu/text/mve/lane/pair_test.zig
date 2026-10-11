//! Covers src/chip/core/cpu/text/mve_lane_pair.zig against DDI0553 syntax.
const v81m = @import("../../v81m.zig");

test "two-lane VMOV prints vector lane pairs and core registers" {
    try v81m.expectTexts(&.{
        .{ .hw1 = 0xEC12, .hw2 = 0x0F01, .text = "vmov q0[2], q0[0], r1, r2" },
        .{ .hw1 = 0xEC1B, .hw2 = 0xEF1C, .text = "vmov q7[3], q7[1], ip, fp" },
        .{ .hw1 = 0xEC0B, .hw2 = 0xAF01, .text = "vmov r1, fp, q5[2], q5[0]" },
        .{ .hw1 = 0xEC02, .hw2 = 0x0F1C, .text = "vmov ip, r2, q0[3], q0[1]" },
    });
}
