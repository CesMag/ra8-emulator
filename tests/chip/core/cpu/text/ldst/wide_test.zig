//! Covers src/chip/core/cpu/text/ldst/wide.zig against its parity digest.
const parity = @import("../parity.zig");

/// For Rt = r1: imm12 edges, then the imm8 offset, pre-indexed,
/// post-indexed (both signs, around the decimal/hex switch at 10) and
/// unprivileged forms. Then SP and PC as Rt, and Rt = r0 for writeback
/// with Rn = Rt.
const hw2 = [_]u16{
    0x1000, 0x1004, 0x1009,          0x100A, 0x1FFF,
    0x1C00, 0x1C04, 0x1C09,          0x1C0A, 0x1CFF,
    0x1D00, 0x1D09, 0x1D0A,          0x1F00, 0x1F09,
    0x1F0A, 0x1FFF, 0x1B00,          0x1B09, 0x1B0A,
    0x1BFF, 0x1900, 0x1909,          0x190A, 0x19FF,
    0x1E00, 0x1E04, 0x1EFF,          0xD004, 0xDB04,
    0xD904, 0xDE04, 0xF004,          0xFB04, 0xFE04,
    0x0D04, 0x0004, 0x1004 | 0x0040,
};

test "ldst_wide matches its parity digest in every addressing form" {
    try parity.expectWideGroupMatches("ldst_wide", 0xFE00, 0xF800, &hw2);
}
