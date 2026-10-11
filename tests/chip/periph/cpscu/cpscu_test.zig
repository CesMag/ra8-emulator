//! CPSCU: the chip-level attribution words behind PRCR_S.PRC4.
const std = @import("std");
const ra8 = @import("ra8");

const cpscu = ra8.chip.periph.cpscu;
const prcr = ra8.chip.periph.prcr;

/// A gate with PRC4 open, and one with everything locked.
fn gate(open: bool) prcr.Prcr {
    var unit = prcr.Prcr.init();
    if (open) unit.write(prcr.win_base, 2, prcr.unlockWord(prcr.group.sar));
    return unit;
}

fn at(offset: u32) u32 {
    return cpscu.win_base + offset;
}

test "reset leaves every initiator Secure" {
    var lock = gate(false);
    const unit = cpscu.Unit.init(&lock);
    try std.testing.expect(unit.quiet());
    try std.testing.expect(!unit.anyDelegated());
    for (unit.words) |word| try std.testing.expectEqual(cpscu.reset, word);
}

test "an untouched unit stays out of the report" {
    var lock = gate(true);
    const unit = cpscu.Unit.init(&lock);
    try std.testing.expect(unit.quiet());
}

test "with PRC4 open the six words land" {
    var lock = gate(true);
    var unit = cpscu.Unit.init(&lock);
    unit.write(at(cpscu.off.bussara), 4, 1);
    unit.write(at(cpscu.off.bussarb), 4, 1);
    unit.write(at(cpscu.off.bussarc), 4, 1);
    unit.write(at(cpscu.off.mmpusara), 4, 0xFFFF_FFFF);
    unit.write(at(cpscu.off.mmpusarb), 4, 0xFFFF_FFFF);
    unit.write(at(cpscu.off.cpusar), 4, 0);
    try std.testing.expectEqual(@as(u32, 6), unit.writes);
    try std.testing.expectEqual(@as(u32, 0), unit.locked_writes);
    try std.testing.expectEqual(@as(u32, 1), unit.wordOf(.bussara));
    try std.testing.expectEqual(@as(u32, 0xFFFF_FFFF), unit.wordOf(.mmpusarb));
    try std.testing.expectEqual(@as(u32, 0), unit.wordOf(.cpusar));
    try std.testing.expect(unit.anyDelegated());
    try std.testing.expect(!unit.quiet());
}

test "with PRC4 shut the word never lands" {
    var lock = gate(false);
    var unit = cpscu.Unit.init(&lock);
    unit.write(at(cpscu.off.mmpusara), 4, 0xFFFF_FFFF);
    try std.testing.expectEqual(@as(u32, 0), unit.wordOf(.mmpusara));
    try std.testing.expectEqual(@as(u32, 1), unit.locked_writes);
    try std.testing.expectEqual(@as(u32, 0), unit.writes);
    try std.testing.expect(!unit.anyDelegated());
    try std.testing.expect(!unit.quiet());
}

test "relocking PRC4 stops the next store, and keeps what landed" {
    var lock = gate(true);
    var unit = cpscu.Unit.init(&lock);
    unit.write(at(cpscu.off.bussara), 4, 1);
    lock.write(prcr.win_base, 2, prcr.unlockWord(0));
    unit.write(at(cpscu.off.bussarb), 4, 1);
    try std.testing.expectEqual(@as(u32, 1), unit.wordOf(.bussara));
    try std.testing.expectEqual(@as(u32, 0), unit.wordOf(.bussarb));
    try std.testing.expectEqual(@as(u32, 1), unit.locked_writes);
}

test "another group open is not PRC4" {
    var open_other = prcr.Prcr.init();
    open_other.write(prcr.win_base, 2, prcr.unlockWord(prcr.group.lpm));
    var unit = cpscu.Unit.init(&open_other);
    unit.write(at(cpscu.off.cpusar), 4, 3);
    try std.testing.expectEqual(@as(u32, 0), unit.wordOf(.cpusar));
    try std.testing.expectEqual(@as(u32, 1), unit.locked_writes);
}

test "a read is never gated" {
    var lock = gate(true);
    var unit = cpscu.Unit.init(&lock);
    unit.write(at(cpscu.off.bussarc), 4, 0xA5A5_1234);
    lock.write(prcr.win_base, 2, prcr.unlockWord(0));
    try std.testing.expectEqual(@as(u32, 0xA5A5_1234), unit.read(at(cpscu.off.bussarc), 4));
}

test "a gap in the window is not a register" {
    var lock = gate(true);
    var unit = cpscu.Unit.init(&lock);
    unit.write(at(0x08), 4, 0xFFFF_FFFF);
    try std.testing.expectEqual(@as(u32, 1), unit.reserved_writes);
    try std.testing.expectEqual(@as(u32, 0), unit.writes);
    try std.testing.expectEqual(@as(u32, 0), unit.read(at(0x08), 4));
    try std.testing.expect(!unit.anyDelegated());
}

test "a reserved offset is reserved whether or not PRC4 is open" {
    var lock = gate(false);
    var unit = cpscu.Unit.init(&lock);
    unit.write(at(0x08), 4, 0xFFFF_FFFF);
    try std.testing.expectEqual(@as(u32, 1), unit.reserved_writes);
    try std.testing.expectEqual(@as(u32, 0), unit.locked_writes);
}

test "a byte store names its own lane" {
    var lock = gate(true);
    var unit = cpscu.Unit.init(&lock);
    unit.write(at(cpscu.off.mmpusarb) + 2, 1, 0xAB);
    try std.testing.expectEqual(@as(u32, 0x00AB_0000), unit.wordOf(.mmpusarb));
    try std.testing.expectEqual(@as(u32, 0xAB), unit.read(at(cpscu.off.mmpusarb) + 2, 1));
}

test "a store does not bleed into the next register" {
    var lock = gate(true);
    var unit = cpscu.Unit.init(&lock);
    unit.write(at(cpscu.off.mmpusara), 4, 0xFFFF_FFFF);
    try std.testing.expectEqual(@as(u32, 0), unit.wordOf(.mmpusarb));
}

test "an unwired unit accepts nothing" {
    var unit = cpscu.Unit{};
    unit.write(at(cpscu.off.bussara), 4, 1);
    try std.testing.expectEqual(@as(u32, 0), unit.wordOf(.bussara));
    try std.testing.expectEqual(@as(u32, 1), unit.locked_writes);
}

test "the block covers every register and nothing past the last" {
    var lock = gate(true);
    var unit = cpscu.Unit.init(&lock);
    const window = unit.block();
    try std.testing.expectEqual(cpscu.win_base, window.base);
    try std.testing.expectEqual(cpscu.win_span, window.size);
    for (cpscu.layout) |offset| try std.testing.expect(offset < window.size);
    try std.testing.expectEqual(@as(usize, cpscu.register_count), cpscu.layout.len);
}
