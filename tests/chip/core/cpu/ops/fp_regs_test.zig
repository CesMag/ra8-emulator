//! Covers src/chip/core/cpu/ops/fp_regs.zig.
const std = @import("std");
const ra8 = @import("ra8");
const fp_regs = ra8.chip.core.cpu.ops.fp_regs;
const Bank = ra8.chip.core.cpu.fpu.bank.Bank;
const format = ra8.chip.core.cpu.fpu.format;

test "single registers are V:X and doubles X:V" {
    try std.testing.expectEqual(@as(u5, 31), fp_regs.index(15, 1, false));
    try std.testing.expectEqual(@as(u5, 6), fp_regs.index(3, 0, false));
    try std.testing.expectEqual(@as(u5, 19), fp_regs.index(3, 1, true));
    try std.testing.expectEqual(@as(u5, 3), fp_regs.index(3, 0, true));
}

test "M-profile has no D16 and above" {
    try std.testing.expect(fp_regs.exists(15, true));
    try std.testing.expect(!fp_regs.exists(16, true));
    try std.testing.expect(fp_regs.exists(31, false));
}

test "read and write go through the bank by precision" {
    var bank: Bank = .{};
    fp_regs.write(format.double, &bank, 1, 0x1122_3344_5566_7788);
    try std.testing.expectEqual(@as(u32, 0x5566_7788), fp_regs.read(format.single, &bank, 2));
    try std.testing.expectEqual(@as(u32, 0x1122_3344), fp_regs.read(format.single, &bank, 3));
    try std.testing.expectEqual(@as(u64, 0x1122_3344_5566_7788), fp_regs.read(format.double, &bank, 1));
}

test "half precision reads the low half and writes Zeros(16):value" {
    var bank: Bank = .{};
    bank.writeS(7, 0xABCD_1234);
    try std.testing.expectEqual(@as(u16, 0x1234), fp_regs.read(format.half, &bank, 7));
    fp_regs.write(format.half, &bank, 7, 0x5678);
    try std.testing.expectEqual(@as(u32, 0x5678), bank.readS(7));
}
