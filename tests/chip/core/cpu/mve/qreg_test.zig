//! Covers src/chip/core/cpu/mve/qreg.zig.
const std = @import("std");
const ra8 = @import("ra8");
const qreg = ra8.chip.core.cpu.mve.qreg;
const Bank = ra8.chip.core.cpu.fpu.bank.Bank;

test "Q1 is D3:D2, S4 holding the low word" {
    var bank: Bank = .{};
    bank.writeS(4, 0x0302_0100);
    bank.writeS(5, 0x0706_0504);
    bank.writeD(3, 0x0F0E_0D0C_0B0A_0908);
    try std.testing.expectEqual(@as(u128, 0x0F0E0D0C_0B0A0908_07060504_03020100), qreg.read(&bank, 1));
}

test "write Q7 then read it back through S28-S31" {
    var bank: Bank = .{};
    qreg.write(&bank, 7, 0xDDDDDDDD_CCCCCCCC_BBBBBBBB_AAAAAAAA);
    try std.testing.expectEqual(@as(u32, 0xAAAA_AAAA), bank.readS(28));
    try std.testing.expectEqual(@as(u32, 0xDDDD_DDDD), bank.readS(31));
    try std.testing.expectEqual(@as(u32, 0), bank.readS(27));
}

test "element widths and counts" {
    try std.testing.expectEqual(@as(u8, 16), qreg.lanes(.byte));
    try std.testing.expectEqual(@as(u8, 8), qreg.lanes(.half));
    try std.testing.expectEqual(@as(u8, 4), qreg.lanes(.word));
    try std.testing.expectEqual(@as(u8, 32), qreg.bits(.word));
}

test "elem and setElem number from the low end" {
    const v: u128 = 0x0F0E0D0C_0B0A0908_07060504_03020100;
    try std.testing.expectEqual(@as(u32, 0x0F), qreg.elem(v, .byte, 15));
    try std.testing.expectEqual(@as(u32, 0x0504), qreg.elem(v, .half, 2));
    try std.testing.expectEqual(@as(u32, 0x0F0E_0D0C), qreg.elem(v, .word, 3));
    const w = qreg.setElem(v, .half, 7, 0xABCD_1234);
    try std.testing.expectEqual(@as(u128, 0x12340D0C_0B0A0908_07060504_03020100), w);
    try std.testing.expectEqual(@as(u128, 0xFF), qreg.setElem(0, .byte, 0, 0xFFFF));
}
