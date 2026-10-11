//! Covers MVE interleaving load/store text against DDI0553 B5.
const v81m = @import("../v81m.zig");

test "interleaving forms print register lists and patterns" {
    try v81m.expectTexts(&.{
        .{ .hw1 = 0xFC91, .hw2 = 0x1E00, .text = "vld20.8 {q0, q1}, [r1]" },
        .{ .hw1 = 0xFC91, .hw2 = 0x1E20, .text = "vld21.8 {q0, q1}, [r1]" },
        .{ .hw1 = 0xFC91, .hw2 = 0x1F61, .text = "vld43.32 {q0, q1, q2, q3}, [r1]" },
        .{ .hw1 = 0xFC81, .hw2 = 0x1E01, .text = "vst40.8 {q0, q1, q2, q3}, [r1]" },
    });
}
