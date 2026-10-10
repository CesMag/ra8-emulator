//! PRCR: the key, the retained mask, and the reads that do not carry the key.
const std = @import("std");
const ra8 = @import("ra8");

const prcr = ra8.chip.periph.prcr;

test "a keyed write retains only the group bits" {
    var unit = prcr.Prcr.init();
    unit.write(prcr.win_base, 2, prcr.unlockWord(prcr.group.lpm));
    try std.testing.expect(unit.unlocked(prcr.group.lpm));
    try std.testing.expectEqual(@as(u16, prcr.group.lpm), unit.groups);
    try std.testing.expectEqual(@as(u32, 1), unit.unlocks);
}

test "a write without the 0xA5 key unlocks nothing and is counted" {
    var unit = prcr.Prcr.init();
    unit.write(prcr.win_base, 2, prcr.group.lpm);
    try std.testing.expect(!unit.unlocked(prcr.group.lpm));
    try std.testing.expectEqual(@as(u32, 1), unit.bad_key);
    try std.testing.expectEqual(@as(u32, 0), unit.unlocks);
}

test "a bad key leaves an earlier unlock standing" {
    var unit = prcr.Prcr.init();
    unit.write(prcr.win_base, 2, prcr.unlockWord(prcr.group.cgc | prcr.group.lpm));
    unit.write(prcr.win_base, 2, 0x1234);
    try std.testing.expect(unit.unlocked(prcr.group.cgc));
    try std.testing.expect(unit.unlocked(prcr.group.lpm));
    try std.testing.expectEqual(@as(u32, 1), unit.bad_key);
}

test "a keyed write with no group bits locks everything again" {
    var unit = prcr.Prcr.init();
    unit.write(prcr.win_base, 2, prcr.unlockWord(prcr.group.all));
    unit.write(prcr.win_base, 2, prcr.key.value);
    try std.testing.expect(!unit.unlocked(prcr.group.cgc));
    try std.testing.expectEqual(@as(u16, 0), unit.groups);
    // Only the first write enabled anything, so only it counts as an unlock.
    try std.testing.expectEqual(@as(u32, 1), unit.unlocks);
}

test "reserved bits are not retained" {
    var unit = prcr.Prcr.init();
    unit.write(prcr.win_base, 2, prcr.key.value | 0x00C4);
    try std.testing.expectEqual(@as(u16, 0), unit.groups);
}

test "unlocked asks for every group in the mask, not any of them" {
    var unit = prcr.Prcr.init();
    unit.write(prcr.win_base, 2, prcr.unlockWord(prcr.group.cgc));
    try std.testing.expect(unit.unlocked(prcr.group.cgc));
    try std.testing.expect(!unit.unlocked(prcr.group.cgc | prcr.group.rst));
}

test "the key byte reads back as zero" {
    var unit = prcr.Prcr.init();
    unit.write(prcr.win_base, 2, prcr.unlockWord(prcr.group.rst));
    try std.testing.expectEqual(@as(u32, prcr.group.rst), unit.read(prcr.win_base, 2));
    try std.testing.expectEqual(@as(u32, prcr.group.rst), unit.read(prcr.win_base, 1));
    try std.testing.expectEqual(@as(u32, 0), unit.read(prcr.win_base + 1, 1));
}

test "a byte store can never carry the key, so it unlocks nothing" {
    var unit = prcr.Prcr.init();
    unit.write(prcr.win_base, 1, prcr.group.lpm);
    try std.testing.expect(!unit.unlocked(prcr.group.lpm));
    try std.testing.expectEqual(@as(u32, 1), unit.bad_key);
}

test "a byte store to the high half carries the key on its own" {
    var unit = prcr.Prcr.init();
    unit.write(prcr.win_base + 1, 1, 0xA5);
    try std.testing.expectEqual(@as(u32, 0), unit.bad_key);
    try std.testing.expectEqual(@as(u16, 0), unit.groups);
}

test "an untouched unit stays out of the report" {
    var unit = prcr.Prcr.init();
    try std.testing.expect(unit.quiet());
    unit.write(prcr.win_base, 2, 0);
    try std.testing.expect(!unit.quiet());
}

test "the block answers for its own window through the bus" {
    var bus = ra8.chip.periph.registry.Bus.init(std.testing.allocator);
    defer bus.deinit();
    var unit = prcr.Prcr.init();
    try bus.add(unit.block());
    bus.write(prcr.win_base, 2, prcr.unlockWord(prcr.group.pvd));
    try std.testing.expectEqual(@as(u32, prcr.group.pvd), bus.read(prcr.win_base, 2));
    try std.testing.expect(unit.unlocked(prcr.group.pvd));
}
