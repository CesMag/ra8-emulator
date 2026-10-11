//! Covers src/chip/core/cpu/text/ldr_literal_wide.zig against its parity digest.
const parity = @import("../../parity.zig");

/// Zero, decimal and hex offsets around the ten boundary, the largest
/// offset, Rt of SP and PC, and a few other registers.
const hw2 = [_]u16{
    0x1000, 0x1004, 0x1009, 0x100A, 0x1FFF, 0x1123,
    0xD004, 0xF004, 0xF000, 0xD000, 0x0010, 0x7FF0,
    0xC008, 0x3400, 0x2001, 0xE00C,
};

test "ldr_literal_wide matches its parity digest for every size and sign" {
    try parity.expectWideGroupMatches("ldr_literal_wide", 0xFE1F, 0xF81F, &hw2);
}
