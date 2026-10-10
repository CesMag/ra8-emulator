//! Covers src/chip/core/cpu/qarma.zig against DDI0553B ComputePAC.
const std = @import("std");
const ra8 = @import("ra8");
const qarma = ra8.chip.core.cpu.ops.qarma;

test "QARMA5 matches the 64-bit published known-answer vector" {
    const key: qarma.Key = .{ 0xE0A4_88E9, 0xEC28_02D4, 0x9804_E94B, 0x84BE_85CE };
    try std.testing.expectEqual(
        @as(u64, 0xC003_B939_99B3_3765),
        qarma.compute(0xFB62_3599_DA6E_8127, 0x477D_469D_EC0B_8762, key),
    );
}

test "PAC takes the low word of QARMA over the zero-extended inputs" {
    const key: qarma.Key = .{ 1, 2, 3, 4 };
    try std.testing.expectEqual(
        @as(u32, @truncate(qarma.compute(0x1234_5678, 0x9ABC_DEF0, key))),
        qarma.pac(0x1234_5678, 0x9ABC_DEF0, key),
    );
}
