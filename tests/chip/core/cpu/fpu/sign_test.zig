const std = @import("std");
const ra8 = @import("ra8");
const sign = ra8.chip.core.cpu.fpu.sign;

test "negating twice gives the operand back, bit for bit" {
    const ops = [_]u32{ 0, 0x8000_0000, 0x7FC0_0001, 0x7F80_0001, 0x1234_5678 };
    for (ops) |op| try std.testing.expectEqual(op, sign.neg32(sign.neg32(op)));
}

test "abs only ever clears the sign bit" {
    try std.testing.expectEqual(@as(u32, 0x7FFF_FFFF), sign.abs32(0xFFFF_FFFF));
    try std.testing.expectEqual(@as(u64, 0x7FFF_FFFF_FFFF_FFFF), sign.abs64(0xFFFF_FFFF_FFFF_FFFF));
}

test "the double-precision sign is bit 63" {
    try std.testing.expectEqual(@as(u64, 1 << 63), sign.neg64(0));
}
