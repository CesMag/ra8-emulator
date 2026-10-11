//! Covers src/chip/core/cpu/text/lob.zig and src/chip/core/cpu/text/mve/lob_tp.zig
//! against the Arm ARM syntax. Every case sits at 0x0200_0100, so the next
//! instruction is 0x0200_0104.
const v81m = @import("v81m.zig");

test "DLS, WLS and LE, WLS forward and LE backward" {
    try v81m.expectTexts(&.{
        .{ .hw1 = 0xF040, .hw2 = 0xE001, .text = "dls lr, r0" },
        .{ .hw1 = 0xF041, .hw2 = 0xC011, .text = "wls lr, r1, #0x2000124" },
        .{ .hw1 = 0xF042, .hw2 = 0xC803, .text = "wls lr, r2, #0x200010a" },
        .{ .hw1 = 0xF00F, .hw2 = 0xC009, .text = "le lr, #0x20000f4" },
    });
}

test "DLSTP, WLSTP, LETP and LCTP with the element size" {
    try v81m.expectTexts(&.{
        .{ .hw1 = 0xF020, .hw2 = 0xE001, .text = "dlstp.32 lr, r0" },
        .{ .hw1 = 0xF03C, .hw2 = 0xE001, .text = "dlstp.64 lr, ip" },
        .{ .hw1 = 0xF003, .hw2 = 0xC011, .text = "wlstp.8 lr, r3, #0x2000124" },
        .{ .hw1 = 0xF01F, .hw2 = 0xC009, .text = "letp lr, #0x20000f4" },
        .{ .hw1 = 0xF00F, .hw2 = 0xE001, .text = "lctp" },
    });
}
