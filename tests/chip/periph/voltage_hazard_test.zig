const std = @import("std");
const ra8 = @import("ra8");
const hazard = ra8.chip.periph.voltage_hazard;
const vscr = ra8.chip.periph.vscr;
const prcr = ra8.chip.periph.prcr;

const Fixture = struct {
    protection: prcr.Prcr,
    voltage: vscr.Unit,
    watch: hazard.Watch,

    fn init(self: *Fixture) void {
        self.protection = prcr.Prcr.init();
        self.voltage = vscr.Unit.init(&self.protection);
        self.watch = hazard.Watch.init(&self.voltage);
    }

    fn unlock(self: *Fixture) void {
        self.protection.write(prcr.win_base, 2, prcr.unlockWord(vscr.guard));
    }

    /// Step 2: drop the core out of the high-voltage range.
    fn dropVoltage(self: *Fixture) void {
        self.unlock();
        self.voltage.write(vscr.win_base, 4, vscr.bit.vscm);
    }
};

test "an untouched watch stays out of the report" {
    var f: Fixture = undefined;
    f.init();
    try std.testing.expect(f.watch.quiet());
    try std.testing.expectEqual(@as(u32, 0), f.watch.lifts);
    try std.testing.expectEqual(@as(u32, 0), f.watch.brownouts);
}

test "a select that does not lift the core is not a hazard" {
    var f: Fixture = undefined;
    f.init();
    f.watch.selecting(false);
    f.watch.selecting(false);
    try std.testing.expect(f.watch.quiet());
    try std.testing.expectEqual(@as(u32, 0), f.watch.lifts);
}

test "a PLL select with the high-voltage range still selected is the brown-out" {
    var f: Fixture = undefined;
    f.init();
    f.watch.selecting(true);
    try std.testing.expect(!f.watch.quiet());
    try std.testing.expectEqual(@as(u32, 1), f.watch.lifts);
    try std.testing.expectEqual(@as(u32, 1), f.watch.brownouts);
}

test "the driver's order leaves the lift counted and the hazard clear" {
    var f: Fixture = undefined;
    f.init();
    f.dropVoltage();
    try std.testing.expectEqual(vscr.Range.not_high_voltage, f.voltage.range());
    f.watch.selecting(true);
    try std.testing.expectEqual(@as(u32, 1), f.watch.lifts);
    try std.testing.expectEqual(@as(u32, 0), f.watch.brownouts);
}

test "the range is read at the instant of each select, not once" {
    var f: Fixture = undefined;
    f.init();
    f.watch.selecting(true);
    f.dropVoltage();
    f.watch.selecting(true);
    try std.testing.expectEqual(@as(u32, 2), f.watch.lifts);
    try std.testing.expectEqual(@as(u32, 1), f.watch.brownouts);
}

test "a store VSCR never took leaves the core in the high-voltage range" {
    var f: Fixture = undefined;
    f.init();
    // No unlock, so PRC0 is shut and the store is discarded.
    f.voltage.write(vscr.win_base, 4, vscr.bit.vscm);
    try std.testing.expectEqual(@as(u32, 1), f.voltage.dropped_locked);
    f.watch.selecting(true);
    try std.testing.expectEqual(@as(u32, 1), f.watch.brownouts);
}
