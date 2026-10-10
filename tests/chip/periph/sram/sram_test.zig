//! Covers src/chip/periph/sram/sram.zig.
const std = @import("std");
const sram = @import("ra8").chip.periph.sram;

const esr = sram.win_base + sram.off_esr;
const esclr = sram.win_base + sram.off_esclr;

/// A controller with the configuration registers already open, which is
/// what every self-test here is about. The lock itself is covered in
/// sram_lock_test.zig.
fn unit() sram.Sram {
    var block = sram.Sram.init();
    unlock(&block);
    return block;
}

fn unlock(block: *sram.Sram) void {
    block.write(sram.win_base + sram.protection.off.prcr_s, 2, sram.protection.key.unlock);
}

fn relock(block: *sram.Sram) void {
    block.write(sram.win_base + sram.protection.off.prcr_s, 2, sram.protection.key.lock);
}

/// The three phases ra8_sram_self_test drives on one bank, in order.
fn selfTest(block: *sram.Sram, bank: usize) void {
    const cr = sram.crAddress(bank);
    block.write(cr, 1, sram.phase.write);
    block.write(cr, 1, sram.phase.bypass);
    block.write(cr, 1, sram.phase.verify);
}

test "a fresh controller has no errors and nothing to report" {
    var block = sram.Sram.init();
    try std.testing.expectEqual(@as(u32, 0), block.read(esr, 2));
    try std.testing.expect(block.quiet());
}

test "the three-phase self-test latches both slots of its bank" {
    var block = unit();
    selfTest(&block, 1);
    try std.testing.expect(block.flagged(1, .corrected));
    try std.testing.expect(block.flagged(1, .uncorrectable));
    try std.testing.expectEqual(@as(u32, 1), block.latches);
    const expected = sram.bit(1, .corrected) | sram.bit(1, .uncorrectable);
    try std.testing.expectEqual(@as(u32, expected), block.read(esr, 2));
}

test "a verify that never ran the write phase latches nothing" {
    var block = unit();
    const cr = sram.crAddress(0);
    block.write(cr, 1, sram.phase.bypass);
    block.write(cr, 1, sram.phase.verify);
    try std.testing.expectEqual(@as(u32, 0), block.read(esr, 2));
    try std.testing.expectEqual(@as(u32, 0), block.latches);
}

test "a bank interrupted between bypass and verify has to start over" {
    var block = unit();
    const cr = sram.crAddress(2);
    block.write(cr, 1, sram.phase.write);
    block.write(cr, 1, sram.phase.bypass);
    block.write(cr, 1, 0x00);
    block.write(cr, 1, sram.phase.verify);
    try std.testing.expectEqual(@as(u32, 0), block.latches);
    selfTest(&block, 2);
    try std.testing.expectEqual(@as(u32, 1), block.latches);
}

test "a store to SRAMESR raises nothing and is counted" {
    var block = unit();
    block.write(esr, 2, 0x0003);
    try std.testing.expectEqual(@as(u32, 0), block.read(esr, 2));
    try std.testing.expectEqual(@as(u32, 2), block.faked);
    try std.testing.expect(!block.quiet());
}

test "a store of bits already set is not counted as faked" {
    var block = unit();
    selfTest(&block, 0);
    block.write(esr, 2, block.esr);
    try std.testing.expectEqual(@as(u32, 0), block.faked);
}

test "the latch parks the bank's data offset in both SRAMEAR slots" {
    var block = unit();
    selfTest(&block, 3);
    try std.testing.expectEqual(
        @as(u32, 0x0018_0000),
        block.read(sram.earAddress(3, .corrected), 4),
    );
    try std.testing.expectEqual(
        @as(u32, 0x0018_0000),
        block.read(sram.earAddress(3, .uncorrectable), 4),
    );
}

test "SRAMESCLR clears only the slots its mask names, address included" {
    var block = unit();
    selfTest(&block, 1);
    block.write(esclr, 2, sram.bit(1, .corrected));
    try std.testing.expect(!block.flagged(1, .corrected));
    try std.testing.expect(block.flagged(1, .uncorrectable));
    try std.testing.expectEqual(@as(u32, 0), block.read(sram.earAddress(1, .corrected), 4));
    try std.testing.expectEqual(
        @as(u32, 0x0008_0000),
        block.read(sram.earAddress(1, .uncorrectable), 4),
    );
}

test "SRAMESCLR reads back zero: it is a clear, not a register" {
    var block = unit();
    block.write(esclr, 2, 0xFFFF);
    try std.testing.expectEqual(@as(u32, 0), block.read(esclr, 4));
}

test "one bank's self-test leaves the other three alone" {
    var block = unit();
    selfTest(&block, 2);
    for ([_]usize{ 0, 1, 3 }) |bank| {
        try std.testing.expect(!block.flagged(bank, .corrected));
        try std.testing.expect(!block.flagged(bank, .uncorrectable));
    }
}

test "a byte store to SRAMCR1 leaves the neighbouring bytes alone" {
    var block = unit();
    const cr1 = sram.crAddress(1);
    block.write(cr1, 4, 0x5A5A_5A00);
    block.write(cr1, 1, sram.phase.write);
    try std.testing.expectEqual(@as(u32, 0x5A5A_5A08), block.read(cr1, 4));
    try std.testing.expectEqual(@as(u32, sram.phase.write), block.read(cr1, 1));
}

test "the uninterpreted registers read back exactly what was written" {
    var block = unit();
    const prcr = sram.win_base;
    block.write(prcr, 4, 0x7800_0001);
    try std.testing.expectEqual(@as(u32, 0x7800_0001), block.read(prcr, 4));
    try std.testing.expectEqual(@as(u32, 0x0001), block.read(prcr, 2));
}

test "inject is the seam a real fault source comes in through" {
    var block = unit();
    block.inject(0, .uncorrectable);
    try std.testing.expect(block.flagged(0, .uncorrectable));
    try std.testing.expect(!block.flagged(0, .corrected));
    try std.testing.expectEqual(@as(u32, 1), block.latches);
}

test "an access past the window is ignored" {
    var block = sram.Sram.init();
    block.write(sram.win_base + sram.win_span, 4, 0xFFFF_FFFF);
    try std.testing.expectEqual(@as(u32, 0), block.read(sram.win_base + sram.win_span, 4));
    try std.testing.expect(block.quiet());
}

test "a locked controller refuses the self-test's first phase" {
    var block = sram.Sram.init();
    selfTest(&block, 1);
    try std.testing.expectEqual(@as(u32, 0), block.latches);
    try std.testing.expectEqual(@as(u32, 3), block.lock.blocked);
    try std.testing.expectEqual(@as(u32, 0), block.read(sram.crAddress(1), 1));
}

test "the driver's unlock, write, re-lock is what gets a phase through" {
    var block = sram.Sram.init();
    const cr = sram.crAddress(0);
    unlock(&block);
    block.write(cr, 1, sram.phase.write);
    relock(&block);
    try std.testing.expectEqual(@as(u32, sram.phase.write), block.read(cr, 1));
    block.write(cr, 1, sram.phase.bypass);
    try std.testing.expectEqual(@as(u32, sram.phase.write), block.read(cr, 1));
    try std.testing.expectEqual(@as(u32, 1), block.lock.blocked);
}

test "a wrong key does not open the controller" {
    var block = sram.Sram.init();
    block.write(sram.win_base + sram.protection.off.prcr_s, 2, 0x0001);
    block.write(sram.crAddress(2), 1, sram.phase.write);
    try std.testing.expectEqual(@as(u32, 0), block.read(sram.crAddress(2), 1));
    try std.testing.expectEqual(@as(u32, 1), block.lock.ignored);
}

test "the error side of the block answers with the controller locked" {
    var block = sram.Sram.init();
    block.inject(1, .uncorrectable);
    try std.testing.expect(block.flagged(1, .uncorrectable));
    block.write(esclr, 2, sram.bit(1, .uncorrectable));
    try std.testing.expect(!block.flagged(1, .uncorrectable));
    try std.testing.expectEqual(@as(u32, 0), block.lock.blocked);
}
