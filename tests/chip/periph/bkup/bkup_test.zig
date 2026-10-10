//! VBATT backup: the writes PRCR drops, the ones VBAE drops, and retention.
const std = @import("std");
const ra8 = @import("ra8");

const bkup = ra8.chip.periph.bkup;
const prcr = ra8.chip.periph.prcr;

fn unlocked() prcr.Prcr {
    var protection = prcr.Prcr.init();
    protection.write(prcr.win_base, 2, prcr.unlockWord(prcr.group.lpm));
    return protection;
}

test "a write with PRC1 locked vanishes and reads back as zero" {
    var protection = prcr.Prcr.init();
    var unit = bkup.Bkup.init(&protection);
    unit.write(bkup.slotAddress(0), 4, 0xDEAD_BEEF);
    try std.testing.expectEqual(@as(u32, 0), unit.read(bkup.slotAddress(0), 4));
    try std.testing.expectEqual(@as(u32, 1), unit.dropped_locked);
    try std.testing.expectEqual(@as(u32, 0), unit.writes);
}

test "the same write sticks once PRCR unlocks PRC1" {
    var protection = unlocked();
    var unit = bkup.Bkup.init(&protection);
    unit.write(bkup.slotAddress(0), 4, 0xDEAD_BEEF);
    try std.testing.expectEqual(@as(u32, 0xDEAD_BEEF), unit.read(bkup.slotAddress(0), 4));
    try std.testing.expectEqual(@as(u32, 1), unit.writes);
    try std.testing.expectEqual(@as(u32, 0), unit.dropped_locked);
}

test "VBAE is already armed out of reset" {
    var protection = unlocked();
    var unit = bkup.Bkup.init(&protection);
    try std.testing.expectEqual(@as(u32, bkup.vbtber.reset), unit.read(bkup.win_base, 1));
    try std.testing.expect(unit.read(bkup.win_base, 1) & bkup.vbtber.vbae != 0);
}

test "clearing VBAE drops the next backup write" {
    var protection = unlocked();
    var unit = bkup.Bkup.init(&protection);
    unit.write(bkup.win_base, 1, 0);
    unit.write(bkup.slotAddress(4), 4, 0x1234_5678);
    try std.testing.expectEqual(@as(u32, 0), unit.read(bkup.slotAddress(4), 4));
    try std.testing.expectEqual(@as(u32, 1), unit.dropped_disabled);
    try std.testing.expectEqual(bkup.Drop.disabled, unit.lastDrop());
}

test "VBTBER itself is PRC1-gated, so a locked clear of VBAE changes nothing" {
    var protection = prcr.Prcr.init();
    var unit = bkup.Bkup.init(&protection);
    unit.write(bkup.win_base, 1, 0);
    try std.testing.expectEqual(@as(u32, bkup.vbtber.reset), unit.read(bkup.win_base, 1));
    // A dropped VBTBER write is not a dropped backup write: it is not counted.
    try std.testing.expectEqual(@as(u32, 0), unit.dropped_locked);
}

test "a reset keeps the data and clears the control state" {
    var protection = unlocked();
    var unit = bkup.Bkup.init(&protection);
    unit.write(bkup.slotAddress(8), 4, 0xA5A5_5A5A);
    unit.write(bkup.win_base, 1, 0);
    unit.resetControl();
    try std.testing.expectEqual(@as(u32, 0xA5A5_5A5A), unit.read(bkup.slotAddress(8), 4));
    try std.testing.expectEqual(@as(u32, bkup.vbtber.reset), unit.read(bkup.win_base, 1));
    try std.testing.expectEqual(@as(u32, 0), unit.writes);
}

test "narrow and wide accesses reach the same bytes" {
    var protection = unlocked();
    var unit = bkup.Bkup.init(&protection);
    unit.write(bkup.slotAddress(12), 4, 0x1122_3344);
    try std.testing.expectEqual(@as(u32, 0x44), unit.read(bkup.slotAddress(12), 1));
    try std.testing.expectEqual(@as(u32, 0x2233), unit.read(bkup.slotAddress(13), 2));
    unit.write(bkup.slotAddress(13), 1, 0xEE);
    try std.testing.expectEqual(@as(u32, 0x1122_EE44), unit.read(bkup.slotAddress(12), 4));
}

test "a write runs off the end of the file instead of past it" {
    var protection = unlocked();
    var unit = bkup.Bkup.init(&protection);
    unit.write(bkup.slotAddress(bkup.reg_count - 2), 4, 0xAABB_CCDD);
    try std.testing.expectEqual(@as(u32, 0xCCDD), unit.read(bkup.slotAddress(bkup.reg_count - 2), 2));
    try std.testing.expectEqual(@as(u32, 1), unit.writes);
}

test "an untouched unit stays out of the report" {
    var protection = unlocked();
    var unit = bkup.Bkup.init(&protection);
    try std.testing.expect(unit.quiet());
    unit.write(bkup.slotAddress(0), 1, 1);
    try std.testing.expect(!unit.quiet());
}

test "the #131 sequence end to end through the bus" {
    var bus = ra8.chip.periph.registry.Bus.init(std.testing.allocator);
    defer bus.deinit();
    var protection = prcr.Prcr.init();
    var unit = bkup.Bkup.init(&protection);
    try bus.add(protection.block());
    try bus.add(unit.block());

    // Locked: the write vanishes, exactly as on the bench.
    bus.write(bkup.slotAddress(0), 4, 0x5AA5_1234);
    try std.testing.expectEqual(@as(u32, 0), bus.read(bkup.slotAddress(0), 4));

    // PRCR = 0xA502, then the identical write sticks.
    bus.write(prcr.win_base, 2, prcr.unlockWord(prcr.group.lpm));
    bus.write(bkup.slotAddress(0), 4, 0x5AA5_1234);
    try std.testing.expectEqual(@as(u32, 0x5AA5_1234), bus.read(bkup.slotAddress(0), 4));
    try std.testing.expectEqual(@as(u32, 1), unit.dropped_locked);
    try std.testing.expectEqual(@as(u32, 1), unit.writes);
}
