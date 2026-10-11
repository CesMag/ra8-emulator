//! Covers MVE vector-base immediate gather/scatter printers per DDI0553 C2.
const v81m = @import("../../v81m.zig");

test "vector-base gather prints signed byte displacement and writeback" {
    try v81m.expectTexts(&.{
        .{ .hw1 = 0xFD9A, .hw2 = 0x5E03, .text = "vldrw.u32 q2, [q5, #+12]" },
        .{ .hw1 = 0xFD38, .hw2 = 0x7F03, .text = "vldrd.u64 q3, [q4, #-24]!" },
    });
}
