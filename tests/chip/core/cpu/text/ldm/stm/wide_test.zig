//! Covers src/chip/core/cpu/text/ldm_stm_wide.zig against its parity digest.
const parity = @import("../../parity.zig");

/// Lists of one, two and many registers, with LR, PC and SP, the PUSH/POP
/// shapes, and lists that hold a low Rn (the writeback-overlap cases).
const hw2 = [_]u16{
    0x0006, 0x4010, 0x8010, 0x4FF0, 0x8FF0, 0x0001,
    0x8000, 0x2006, 0xC006, 0x0007, 0x1FFF, 0x5FFF,
    0x9FFE, 0x0180, 0x0300, 0x0003,
};

test "ldm_stm_wide matches its parity digest, PUSH.W and POP.W included" {
    try parity.expectWideGroupMatches("ldm_stm_wide", 0xFE40, 0xE800, &hw2);
}
