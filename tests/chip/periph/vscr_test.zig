const std = @import("std");
const ra8 = @import("ra8");
const vscr = ra8.chip.periph.vscr;
const prcr = ra8.chip.periph.prcr;

const Fixture = struct {
    protection: prcr.Prcr,
    unit: vscr.Unit,

    fn init(self: *Fixture) void {
        self.protection = prcr.Prcr.init();
        self.unit = vscr.Unit.init(&self.protection);
    }

    fn unlock(self: *Fixture) void {
        self.protection.write(prcr.win_base, 2, prcr.unlockWord(vscr.guard));
    }

    fn relock(self: *Fixture) void {
        self.protection.write(prcr.win_base, 2, prcr.unlockWord(0));
    }
};

test "the core starts in the high voltage range and says nothing" {
    var fix: Fixture = undefined;
    fix.init();
    try std.testing.expect(fix.unit.quiet());
    try std.testing.expectEqual(vscr.Range.high_voltage, fix.unit.range());
    try std.testing.expectEqual(@as(u32, 0), fix.unit.read(vscr.win_base, 4));
}

test "a store with PRC0 locked is dropped and counted" {
    var fix: Fixture = undefined;
    fix.init();
    fix.unit.write(vscr.win_base, 4, vscr.bit.vscm);
    try std.testing.expectEqual(@as(u32, 1), fix.unit.dropped_locked);
    try std.testing.expectEqual(@as(u32, 0), fix.unit.stores);
    try std.testing.expectEqual(vscr.Range.high_voltage, fix.unit.range());
}

test "the bring-up drop lands once PRC0 is open" {
    var fix: Fixture = undefined;
    fix.init();
    fix.unlock();
    fix.unit.write(vscr.win_base, 4, vscr.bit.vscm);
    try std.testing.expectEqual(vscr.Range.not_high_voltage, fix.unit.range());
    try std.testing.expectEqual(@as(u32, 1), fix.unit.stores);
    try std.testing.expectEqual(@as(u32, 1), fix.unit.transitions);
}

test "VSCMTSF reads clear the moment the driver looks" {
    var fix: Fixture = undefined;
    fix.init();
    fix.unlock();
    fix.unit.write(vscr.win_base, 4, vscr.bit.vscm);
    const word = fix.unit.read(vscr.win_base, 4);
    try std.testing.expectEqual(@as(u32, vscr.bit.vscm), word);
    try std.testing.expectEqual(@as(u32, 0), word & vscr.bit.vscmtsf);
}

test "a store cannot raise VSCMTSF, and the attempt is counted" {
    var fix: Fixture = undefined;
    fix.init();
    fix.unlock();
    fix.unit.write(vscr.win_base, 4, vscr.bit.vscm | vscr.bit.vscmtsf);
    try std.testing.expectEqual(@as(u32, vscr.bit.vscm), fix.unit.read(vscr.win_base, 4));
    try std.testing.expectEqual(@as(u32, 1), fix.unit.flag_writes);
    try std.testing.expectEqual(vscr.Range.not_high_voltage, fix.unit.range());
}

test "the wait loop finishes rather than spinning on a stored flag" {
    var fix: Fixture = undefined;
    fix.init();
    fix.unlock();
    fix.unit.write(vscr.win_base, 4, vscr.bit.vscm | vscr.bit.vscmtsf);
    var spins: u32 = 0;
    while (fix.unit.read(vscr.win_base, 4) & vscr.bit.vscmtsf != 0) : (spins += 1) {
        if (spins > 8) break;
    }
    try std.testing.expectEqual(@as(u32, 0), spins);
}

test "the bits above VSCM and VSCMTSF are not kept" {
    var fix: Fixture = undefined;
    fix.init();
    fix.unlock();
    fix.unit.write(vscr.win_base, 4, 0xFFFF_FFFF);
    try std.testing.expectEqual(@as(u32, vscr.bit.vscm), fix.unit.read(vscr.win_base, 4));
}

test "clearing VSCM again counts a second transition" {
    var fix: Fixture = undefined;
    fix.init();
    fix.unlock();
    fix.unit.write(vscr.win_base, 4, vscr.bit.vscm);
    fix.unit.write(vscr.win_base, 4, 0);
    try std.testing.expectEqual(vscr.Range.high_voltage, fix.unit.range());
    try std.testing.expectEqual(@as(u32, 2), fix.unit.transitions);
    try std.testing.expectEqual(@as(u32, 2), fix.unit.stores);
}

test "writing the same range twice is a store but not a transition" {
    var fix: Fixture = undefined;
    fix.init();
    fix.unlock();
    fix.unit.write(vscr.win_base, 4, vscr.bit.vscm);
    fix.unit.write(vscr.win_base, 4, vscr.bit.vscm);
    try std.testing.expectEqual(@as(u32, 1), fix.unit.transitions);
    try std.testing.expectEqual(@as(u32, 2), fix.unit.stores);
}

test "a byte store merges into the word and a byte load cuts it" {
    var fix: Fixture = undefined;
    fix.init();
    fix.unlock();
    fix.unit.write(vscr.win_base, 1, vscr.bit.vscm);
    try std.testing.expectEqual(@as(u32, 1), fix.unit.read(vscr.win_base, 1));
    try std.testing.expectEqual(@as(u32, 0), fix.unit.read(vscr.win_base + 1, 1));
    try std.testing.expectEqual(vscr.Range.not_high_voltage, fix.unit.range());
}

test "relocking PRC0 freezes the range" {
    var fix: Fixture = undefined;
    fix.init();
    fix.unlock();
    fix.unit.write(vscr.win_base, 4, vscr.bit.vscm);
    fix.relock();
    fix.unit.write(vscr.win_base, 4, 0);
    try std.testing.expectEqual(vscr.Range.not_high_voltage, fix.unit.range());
    try std.testing.expectEqual(@as(u32, 1), fix.unit.dropped_locked);
}

test "the group is PRC0, not the low-power one" {
    try std.testing.expectEqual(prcr.group.cgc, vscr.guard);
    var fix: Fixture = undefined;
    fix.init();
    fix.protection.write(prcr.win_base, 2, prcr.unlockWord(prcr.group.lpm));
    fix.unit.write(vscr.win_base, 4, vscr.bit.vscm);
    try std.testing.expectEqual(@as(u32, 1), fix.unit.dropped_locked);
}

test "the range names read the way the report prints them" {
    try std.testing.expectEqualStrings("high voltage", vscr.Range.high_voltage.name());
    try std.testing.expectEqualStrings("not high voltage", vscr.Range.not_high_voltage.name());
}

test "one bus window, four bytes wide" {
    var fix: Fixture = undefined;
    fix.init();
    const one = fix.unit.block();
    try std.testing.expectEqual(vscr.win_base, one.base);
    try std.testing.expectEqual(@as(u32, 4), one.size);
}
