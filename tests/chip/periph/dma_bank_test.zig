//! Covers src/chip/periph/dma_bank.zig: the module gate over the DMAC channels,
//! and the shadow behind it.
const std = @import("std");
const ra8 = @import("ra8");
const dma_bank = ra8.chip.periph.dma_bank;

test "the module is stopped out of reset" {
    var bank = dma_bank.Bank.init();
    try std.testing.expect(!bank.started());
    try std.testing.expect(bank.quiet());
}

test "DMAST.DMST starts the module and reads back" {
    var bank = dma_bank.Bank.init();
    bank.write(dma_bank.win_base, 1, dma_bank.field.dmst);
    try std.testing.expect(bank.started());
    try std.testing.expectEqual(
        @as(u32, dma_bank.field.dmst),
        bank.read(dma_bank.win_base, 1),
    );
}

test "a register behind DMAST is shadowed and counted, not modelled" {
    var bank = dma_bank.Bank.init();
    bank.write(dma_bank.win_base + 0x40, 4, 0xDEAD_BEEF);
    try std.testing.expectEqual(@as(u32, 0xDEAD_BEEF), bank.read(dma_bank.win_base + 0x40, 4));
    try std.testing.expectEqual(@as(u32, 2), bank.unmodelled);
    try std.testing.expect(!bank.quiet());
}

test "an access past the end of the bank reads zero and writes nothing" {
    var bank = dma_bank.Bank.init();
    bank.write(dma_bank.win_base + dma_bank.win_span, 4, 0x55);
    try std.testing.expectEqual(@as(u32, 0), bank.read(dma_bank.win_base + dma_bank.win_span, 4));
}
