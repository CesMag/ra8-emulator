//! Covers MVE 64-bit gather/scatter printers against DDI0553 C2.4.366/486.
const std = @import("std");
const v81m = @import("../v81m.zig");

test "64-bit gather loads and scatter stores print UXTW scaling" {
    try v81m.expectTexts(&.{
        .{ .hw1 = 0xFC91, .hw2 = 0x0FD3, .text = "vldrd.u64 q0, [r1, q1, uxtw #3]" },
        .{ .hw1 = 0xEC81, .hw2 = 0x0FD3, .text = "vstrd.64 q0, [r1, q1, uxtw #3]" },
    });
}
