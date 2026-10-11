//! Covers src/chip/core/cpu/text/ldst/reg/wide.zig against its parity digest.
const parity = @import("../../parity.zig");

/// Each shift with a low Rm, SP and PC as Rt, SP and PC as Rm (unclaimed),
/// and hw2 with bits [11:6] set (not this group).
const hw2 = [_]u16{
    0x1002, 0x1012, 0x1022, 0x1032, 0x100C, 0x103E,
    0xD002, 0xD032, 0xF002, 0xF012, 0x000D, 0x100F,
    0x0001, 0x7027, 0x1042, 0x1802,
};

test "ldst_reg_wide matches its parity digest for every shift" {
    try parity.expectWideGroupMatches("ldst_reg_wide", 0xFE00, 0xF800, &hw2);
}
