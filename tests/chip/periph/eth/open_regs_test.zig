//! Tests for the ancillary Ethernet setup register bank.
const std = @import("std");
const ra8 = @import("ra8");
const open_regs = ra8.chip.periph.eth.open_regs;

test "setup words retain writes and reserved GWCA words read zero" {
    var bank: open_regs.Bank = .{};
    bank.write(0x403C_D204, 4, 0xA5);
    bank.write(0x403C_E008, 4, 0xFFFF_FFFF);
    try std.testing.expectEqual(@as(u32, 0xA5), bank.read(0x403C_D204, 4));
    try std.testing.expectEqual(@as(u32, 0), bank.read(0x403C_E008, 4));
    try std.testing.expectEqual(@as(usize, 5), bank.blocks().len);
}
