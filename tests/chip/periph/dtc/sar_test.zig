//! Covers src/chip/periph/dtc/sar.zig: DTCSAR, the two controllers'
//! security attribution behind PRCR_S.PRC4.
const std = @import("std");
const ra8 = @import("ra8");

const sar = ra8.chip.periph.dtc.attribution;
const prcr = ra8.chip.periph.prcr;

fn gate(open: bool) prcr.Prcr {
    var unit = prcr.Prcr.init();
    if (open) unit.write(prcr.win_base, 2, prcr.unlockWord(prcr.group.sar));
    return unit;
}

test "reset leaves both controllers Secure and the unit quiet" {
    var lock = gate(true);
    const unit = sar.Unit.init(&lock);
    try std.testing.expect(unit.quiet());
    try std.testing.expectEqual(sar.reset, unit.read(sar.win_base, 4));
    try std.testing.expect(!unit.nonSecure(.cpu0));
    try std.testing.expect(!unit.nonSecure(.cpu1));
}

test "with PRC4 open each bit hands one controller to the Non-secure world" {
    var lock = gate(true);
    var unit = sar.Unit.init(&lock);
    unit.write(sar.win_base, 4, sar.field.dtcstsa1);
    try std.testing.expect(!unit.nonSecure(.cpu0));
    try std.testing.expect(unit.nonSecure(.cpu1));
    try std.testing.expectEqual(@as(u32, 1), unit.writes);
}

test "the reserved bits read zero whatever was written" {
    var lock = gate(true);
    var unit = sar.Unit.init(&lock);
    unit.write(sar.win_base, 4, 0xFFFF_FFFF);
    try std.testing.expectEqual(sar.field.writable, unit.read(sar.win_base, 4));
}

test "a halfword store at +2 reaches DTCSTSA1 alone" {
    var lock = gate(true);
    var unit = sar.Unit.init(&lock);
    unit.write(sar.win_base + 2, 2, 1);
    try std.testing.expectEqual(sar.field.dtcstsa1, unit.word);
    try std.testing.expectEqual(@as(u32, 1), unit.read(sar.win_base + 2, 2));
}

test "with PRC4 shut a store is dropped and counted" {
    var lock = gate(false);
    var unit = sar.Unit.init(&lock);
    unit.write(sar.win_base, 4, sar.field.writable);
    try std.testing.expectEqual(sar.reset, unit.word);
    try std.testing.expectEqual(@as(u32, 1), unit.locked_writes);
    try std.testing.expect(!unit.quiet());
}
