const std = @import("std");
const ra8 = @import("ra8");
const subclock = ra8.chip.periph.subclock;
const prcr = ra8.chip.periph.prcr;

const Fixture = struct {
    protection: prcr.Prcr,
    unit: subclock.Unit,

    fn init(self: *Fixture) void {
        self.protection = prcr.Prcr.init();
        self.unit = subclock.Unit.init(&self.protection);
    }

    fn unlock(self: *Fixture) void {
        self.protection.write(prcr.win_base, 2, prcr.unlockWord(subclock.guard));
    }

    fn relock(self: *Fixture) void {
        self.protection.write(prcr.win_base, 2, prcr.unlockWord(0));
    }

    fn storeMode(self: *Fixture, value: u8) void {
        self.unit.write(subclock.win_base + subclock.regs.somcr, 1, value);
    }

    fn storeControl(self: *Fixture, value: u8) void {
        self.unit.write(subclock.win_base + subclock.regs.sosccr, 1, value);
    }

    /// What ra8_rtc.c's internal_start_count_source writes, in its own order.
    fn startSubClock(self: *Fixture) void {
        self.storeMode(@backingInt(subclock.Drive.standard));
        self.storeControl(0);
    }
};

test "the crystal comes up stopped, which is the documented reset value" {
    var fix: Fixture = undefined;
    fix.init();
    try std.testing.expect(fix.unit.quiet());
    try std.testing.expect(!fix.unit.running());
    try std.testing.expectEqual(
        @as(u32, subclock.field.sostp),
        fix.unit.read(subclock.win_base, 1),
    );
}

test "the RTC bring-up order starts the crystal and keeps the drive" {
    var fix: Fixture = undefined;
    fix.init();
    fix.unlock();
    fix.startSubClock();
    try std.testing.expect(fix.unit.running());
    try std.testing.expectEqual(subclock.Drive.standard, fix.unit.drive());
    try std.testing.expectEqual(@as(u32, 1), fix.unit.starts);
    try std.testing.expectEqual(@as(u32, 0), fix.unit.refused_running);
}

test "a drive change while the crystal swings is refused and counted" {
    var fix: Fixture = undefined;
    fix.init();
    fix.unlock();
    fix.startSubClock();
    fix.storeMode(@backingInt(subclock.Drive.lp3));
    try std.testing.expectEqual(subclock.Drive.standard, fix.unit.drive());
    try std.testing.expectEqual(@as(u32, 1), fix.unit.refused_running);
}

test "stopping the crystal again reopens the drive register" {
    var fix: Fixture = undefined;
    fix.init();
    fix.unlock();
    fix.startSubClock();
    fix.storeMode(@backingInt(subclock.Drive.lp2));
    fix.storeControl(subclock.field.sostp);
    try std.testing.expect(!fix.unit.running());
    fix.storeMode(@backingInt(subclock.Drive.lp2));
    try std.testing.expectEqual(subclock.Drive.lp2, fix.unit.drive());
    try std.testing.expectEqual(@as(u32, 1), fix.unit.refused_running);
}

test "every drive code round-trips while the crystal is stopped" {
    var fix: Fixture = undefined;
    fix.init();
    fix.unlock();
    for ([_]subclock.Drive{ .standard, .lp1, .lp2, .lp3 }) |want| {
        fix.storeMode(@backingInt(want));
        try std.testing.expectEqual(want, fix.unit.drive());
    }
    try std.testing.expectEqual(@as(u32, 0), fix.unit.refused_running);
}

test "a store with PRC0 locked reaches neither register" {
    var fix: Fixture = undefined;
    fix.init();
    fix.startSubClock();
    try std.testing.expect(!fix.unit.running());
    try std.testing.expectEqual(@as(u32, 2), fix.unit.dropped_locked);
    try std.testing.expectEqual(@as(u32, 0), fix.unit.stores);
}

test "relocking PRC0 shuts the window again" {
    var fix: Fixture = undefined;
    fix.init();
    fix.unlock();
    fix.startSubClock();
    fix.relock();
    fix.storeControl(subclock.field.sostp);
    try std.testing.expect(fix.unit.running());
    try std.testing.expectEqual(@as(u32, 1), fix.unit.dropped_locked);
}

test "PRC0 is judged before the ordering rule" {
    var fix: Fixture = undefined;
    fix.init();
    fix.unlock();
    fix.startSubClock();
    fix.relock();
    fix.storeMode(@backingInt(subclock.Drive.lp1));
    try std.testing.expectEqual(@as(u32, 1), fix.unit.dropped_locked);
    try std.testing.expectEqual(@as(u32, 0), fix.unit.refused_running);
}

test "restarting a running crystal is not counted as a fresh start" {
    var fix: Fixture = undefined;
    fix.init();
    fix.unlock();
    fix.startSubClock();
    fix.storeControl(0);
    try std.testing.expectEqual(@as(u32, 1), fix.unit.starts);
    fix.storeControl(subclock.field.sostp);
    fix.storeControl(0);
    try std.testing.expectEqual(@as(u32, 2), fix.unit.starts);
}

test "the two registers read back on their own lanes" {
    var fix: Fixture = undefined;
    fix.init();
    fix.unlock();
    fix.storeMode(@backingInt(subclock.Drive.lp3));
    try std.testing.expectEqual(
        @as(u32, subclock.field.sostp),
        fix.unit.read(subclock.win_base, 1),
    );
    try std.testing.expectEqual(@as(u32, 3), fix.unit.read(subclock.win_base + 1, 1));
    try std.testing.expectEqual(
        @as(u32, 0x0301),
        fix.unit.read(subclock.win_base, 2),
    );
}

test "a halfword store names both registers, and the drive rule still holds" {
    var fix: Fixture = undefined;
    fix.init();
    fix.unlock();
    // Stopped: both bytes land, drive lp1 and SOSTP cleared in one access.
    fix.unit.write(subclock.win_base, 2, 0x0100);
    try std.testing.expect(fix.unit.running());
    try std.testing.expectEqual(subclock.Drive.lp1, fix.unit.drive());
    // Running: the drive byte is refused, and the access carries nothing.
    fix.unit.write(subclock.win_base, 2, 0x0300);
    try std.testing.expectEqual(subclock.Drive.lp1, fix.unit.drive());
    try std.testing.expectEqual(@as(u32, 1), fix.unit.refused_running);
}

test "the window is the two bytes and nothing else" {
    var fix: Fixture = undefined;
    fix.init();
    const one = fix.unit.block();
    try std.testing.expectEqual(subclock.win_base, one.base);
    try std.testing.expectEqual(subclock.win_span, one.size);
    try std.testing.expectEqual(@as(u32, 0x4001_EC00), subclock.win_base);
}

test "the group these sit behind is PRC0, the same as the clock tree" {
    try std.testing.expectEqual(prcr.group.cgc, subclock.guard);
}

test "a refused drive store still breaks quiet" {
    var fix: Fixture = undefined;
    fix.init();
    fix.unlock();
    fix.storeControl(0);
    const before = fix.unit.stores;
    fix.storeMode(@backingInt(subclock.Drive.lp3));
    try std.testing.expect(!fix.unit.quiet());
    try std.testing.expectEqual(before, fix.unit.stores);
}
