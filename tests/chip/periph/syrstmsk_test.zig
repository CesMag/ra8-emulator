//! Covers src/chip/periph/syrstmsk.zig: the reset-source masks, PRC5, and the two
//! watchdog bits that freeze while their watchdog runs.
const std = @import("std");
const ra8 = @import("ra8");

const syrstmsk = ra8.chip.periph.syrstmsk;
const prcr = ra8.chip.periph.prcr;

const a0 = syrstmsk.win_base + syrstmsk.off.msk0;
const a1 = syrstmsk.win_base + syrstmsk.off.msk1;
const a2 = syrstmsk.win_base + syrstmsk.off.msk2;

const Fixture = struct {
    protection: prcr.Prcr,
    wdt: bool,
    iwdt: bool,
    mask: syrstmsk.Mask,

    fn unlock(self: *Fixture) void {
        self.protection.write(prcr.win_base, 2, prcr.unlockWord(syrstmsk.guard));
    }
};

fn fixture(f: *Fixture) void {
    f.protection = prcr.Prcr.init();
    f.wdt = false;
    f.iwdt = false;
    f.mask = syrstmsk.Mask.init(&f.protection, &f.wdt, &f.iwdt);
}

test "a reset board masks nothing and stays quiet" {
    var f: Fixture = undefined;
    fixture(&f);
    try std.testing.expectEqual(@as(u32, 0), f.mask.read(a0, 1));
    try std.testing.expect(f.mask.quiet());
}

test "PRC5 shut discards the store whole" {
    var f: Fixture = undefined;
    fixture(&f);
    f.mask.write(a0, 1, syrstmsk.msk0.bus);
    try std.testing.expectEqual(@as(u32, 0), f.mask.read(a0, 1));
    try std.testing.expectEqual(@as(u32, 1), f.mask.dropped_locked);
    try std.testing.expect(!f.mask.quiet());
}

test "PRC5 open lets all three bytes through" {
    var f: Fixture = undefined;
    fixture(&f);
    f.unlock();
    f.mask.write(a0, 1, syrstmsk.msk0.bus | syrstmsk.msk0.cm);
    f.mask.write(a1, 1, syrstmsk.msk1.clu1);
    f.mask.write(a2, 1, syrstmsk.msk2.pvd2);
    try std.testing.expectEqual(
        @as(u32, syrstmsk.msk0.bus | syrstmsk.msk0.cm),
        f.mask.read(a0, 1),
    );
    try std.testing.expectEqual(@as(u32, syrstmsk.msk1.clu1), f.mask.read(a1, 1));
    try std.testing.expectEqual(@as(u32, syrstmsk.msk2.pvd2), f.mask.read(a2, 1));
    try std.testing.expectEqual(@as(u32, 0), f.mask.dropped_locked);
}

test "IWDTMASK can be set before the watchdog is armed" {
    var f: Fixture = undefined;
    fixture(&f);
    f.unlock();
    f.mask.write(a0, 1, syrstmsk.msk0.iwdt);
    try std.testing.expect(f.mask.disabled0(syrstmsk.msk0.iwdt));
    try std.testing.expectEqual(@as(u32, 0), f.mask.ignored_iwdt);
}

test "IWDTMASK freezes while the independent watchdog runs" {
    var f: Fixture = undefined;
    fixture(&f);
    f.unlock();
    f.iwdt = true;
    f.mask.write(a0, 1, syrstmsk.msk0.iwdt);
    try std.testing.expect(!f.mask.disabled0(syrstmsk.msk0.iwdt));
    try std.testing.expectEqual(@as(u32, 1), f.mask.ignored_iwdt);
    try std.testing.expect(!f.mask.quiet());
}

test "WDT0MASK freezes while the CPU0 watchdog runs" {
    var f: Fixture = undefined;
    fixture(&f);
    f.unlock();
    f.wdt = true;
    f.mask.write(a0, 1, syrstmsk.msk0.wdt0);
    try std.testing.expect(!f.mask.disabled0(syrstmsk.msk0.wdt0));
    try std.testing.expectEqual(@as(u32, 1), f.mask.ignored_wdt0);
}

test "the rest of the byte still lands while a watchdog bit is frozen" {
    var f: Fixture = undefined;
    fixture(&f);
    f.unlock();
    f.wdt = true;
    f.mask.write(a0, 1, syrstmsk.msk0.wdt0 | syrstmsk.msk0.bus);
    // Silicon ignores the one bit, not the whole store.
    try std.testing.expect(!f.mask.disabled0(syrstmsk.msk0.wdt0));
    try std.testing.expect(f.mask.disabled0(syrstmsk.msk0.bus));
}

test "a masked watchdog bit that is already set is not counted again" {
    var f: Fixture = undefined;
    fixture(&f);
    f.unlock();
    f.mask.write(a0, 1, syrstmsk.msk0.wdt0);
    f.wdt = true;
    // The store asks for the value the bit already holds: nothing to ignore.
    f.mask.write(a0, 1, syrstmsk.msk0.wdt0 | syrstmsk.msk0.lm0);
    try std.testing.expectEqual(@as(u32, 0), f.mask.ignored_wdt0);
    try std.testing.expect(f.mask.disabled0(syrstmsk.msk0.lm0));
}

test "clearing a frozen mask bit is ignored too" {
    var f: Fixture = undefined;
    fixture(&f);
    f.unlock();
    f.mask.write(a0, 1, syrstmsk.msk0.iwdt);
    f.iwdt = true;
    f.mask.write(a0, 1, 0);
    try std.testing.expect(f.mask.disabled0(syrstmsk.msk0.iwdt));
    try std.testing.expectEqual(@as(u32, 1), f.mask.ignored_iwdt);
}

test "SYRSTMSK1 and SYRSTMSK2 never freeze" {
    var f: Fixture = undefined;
    fixture(&f);
    f.unlock();
    f.wdt = true;
    f.iwdt = true;
    f.mask.write(a1, 1, syrstmsk.msk1.wdt1);
    f.mask.write(a2, 1, syrstmsk.msk2.pvd1);
    try std.testing.expectEqual(@as(u32, syrstmsk.msk1.wdt1), f.mask.read(a1, 1));
    try std.testing.expectEqual(@as(u32, syrstmsk.msk2.pvd1), f.mask.read(a2, 1));
}
