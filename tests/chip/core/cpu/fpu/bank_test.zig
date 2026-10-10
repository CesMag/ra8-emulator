const std = @import("std");
const ra8 = @import("ra8");
const Bank = ra8.chip.core.cpu.fpu.bank.Bank;

test "D[n] is S[2n+1]:S[2n]" {
    var bank: Bank = .{};
    bank.writeD(3, 0x1122_3344_5566_7788);
    try std.testing.expectEqual(@as(u32, 0x5566_7788), bank.readS(6));
    try std.testing.expectEqual(@as(u32, 0x1122_3344), bank.readS(7));
    bank.writeS(7, 0xAABB_CCDD);
    try std.testing.expectEqual(@as(u64, 0xAABB_CCDD_5566_7788), bank.readD(3));
}

test "writing one S leaves its neighbours alone" {
    var bank: Bank = .{};
    bank.writeD(15, 0xFFFF_FFFF_FFFF_FFFF);
    bank.writeS(30, 0);
    try std.testing.expectEqual(@as(u32, 0xFFFF_FFFF), bank.readS(31));
    try std.testing.expectEqual(@as(u32, 0), bank.readS(29));
}

test "VMOV between two core registers and a D register" {
    var bank: Bank = .{};
    bank.writeCorePair(1, 0xDEAD_BEEF, 0x0123_4567);
    try std.testing.expectEqual(@as(u64, 0x0123_4567_DEAD_BEEF), bank.readD(1));
    const pair = bank.readCorePair(1);
    try std.testing.expectEqual(@as(u32, 0xDEAD_BEEF), pair[0]);
    try std.testing.expectEqual(@as(u32, 0x0123_4567), pair[1]);
}

test "VMOV two core registers into consecutive S registers" {
    var bank: Bank = .{};
    bank.writeSPair(5, 1, 2);
    try std.testing.expectEqual(@as(u32, 1), bank.readS(5));
    try std.testing.expectEqual(@as(u32, 2), bank.readS(6));
    try std.testing.expectEqual(@as(u64, 0x0000_0001_0000_0000), bank.readD(2));
}
