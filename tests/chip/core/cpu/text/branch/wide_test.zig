//! Covers src/chip/core/cpu/text/branch/wide.zig against its parity digest.
const parity = @import("../parity.zig");

/// Each form (B<cond>.W, B.W, BL) with every J1/J2 pairing and the low and
/// high imm11, plus a misc-control hw2 (unclaimed when cond is 0b111x).
const hw2 = [_]u16{
    0x8000, 0x87FF, 0xA000, 0x8800, 0xAFFE,
    0x9000, 0x97FF, 0xB000, 0x9800, 0xBFFE,
    0xD000, 0xD7FF, 0xF000, 0xD800, 0xFFFE,
    0x8F4F,
};

test "branch_wide matches its parity digest for every hw1" {
    try parity.expectWideGroupMatches("branch_wide", 0xF800, 0xF000, &hw2);
}
