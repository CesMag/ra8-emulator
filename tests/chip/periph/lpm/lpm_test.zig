const std = @import("std");
const ra8 = @import("ra8");
const lpm = ra8.chip.periph.lpm;
const lpm_mode = ra8.chip.periph.lpm.mode;
const prcr = ra8.chip.periph.prcr;

const Fixture = struct {
    protection: prcr.Prcr,
    unit: lpm.Unit,

    fn init(self: *Fixture) void {
        self.protection = prcr.Prcr.init();
        self.unit = lpm.Unit.init(&self.protection);
    }

    /// What ra8_lpm_safe_boot does first: key plus PRC1.
    fn unlock(self: *Fixture) void {
        self.protection.write(prcr.win_base, 2, prcr.unlockWord(lpm.guard));
    }

    fn relock(self: *Fixture) void {
        self.protection.write(prcr.win_base, 2, prcr.unlockWord(0));
    }

    fn store(self: *Fixture, which: usize, value: u8) void {
        self.unit.write(lpm.slots[which].address, 1, value);
    }

    fn load(self: *Fixture, which: usize) u32 {
        return self.unit.read(lpm.slots[which].address, 1);
    }
};

test "the three registers read their cold-reset values before anything runs" {
    var fix: Fixture = undefined;
    fix.init();
    try std.testing.expectEqual(@as(u32, 0x40), fix.load(lpm.index.sbycr));
    try std.testing.expectEqual(@as(u32, 0x14), fix.load(lpm.index.dpsbycr));
    try std.testing.expectEqual(@as(u32, 0x00), fix.load(lpm.index.lpscr));
    try std.testing.expect(fix.unit.quiet());
}

test "a store with PRC1 locked is dropped and counted" {
    var fix: Fixture = undefined;
    fix.init();
    fix.store(lpm.index.lpscr, 0x5);
    fix.store(lpm.index.sbycr, 0x00);
    try std.testing.expectEqual(@as(u32, 0x00), fix.load(lpm.index.lpscr));
    try std.testing.expectEqual(@as(u32, 0x40), fix.load(lpm.index.sbycr));
    try std.testing.expectEqual(@as(u32, 2), fix.unit.dropped_locked);
    try std.testing.expectEqual(@as(u32, 0), fix.unit.stores);
    try std.testing.expect(!fix.unit.quiet());
}

test "unlocking PRC1 lets the same store land" {
    var fix: Fixture = undefined;
    fix.init();
    fix.unlock();
    fix.store(lpm.index.lpscr, 0x5);
    try std.testing.expectEqual(@as(u32, 0x5), fix.load(lpm.index.lpscr));
    try std.testing.expectEqual(lpm_mode.Mode.software_standby, fix.unit.state().?);
    try std.testing.expectEqual(@as(u32, 0), fix.unit.dropped_locked);
}

test "relocking PRC1 shuts the window again" {
    var fix: Fixture = undefined;
    fix.init();
    fix.unlock();
    fix.store(lpm.index.lpscr, 0x5);
    fix.relock();
    fix.store(lpm.index.lpscr, 0x0);
    try std.testing.expectEqual(@as(u32, 0x5), fix.load(lpm.index.lpscr));
    try std.testing.expectEqual(@as(u32, 1), fix.unit.dropped_locked);
}

test "the reset path's own three writes land and read back" {
    var fix: Fixture = undefined;
    fix.init();
    fix.unlock();
    fix.store(lpm.index.lpscr, 0x00);
    fix.store(lpm.index.sbycr, 0x40);
    fix.store(lpm.index.dpsbycr, 0x14);
    try std.testing.expectEqual(@as(u32, 0x00), fix.load(lpm.index.lpscr));
    try std.testing.expectEqual(@as(u32, 0x40), fix.load(lpm.index.sbycr));
    try std.testing.expectEqual(@as(u32, 0x14), fix.load(lpm.index.dpsbycr));
    try std.testing.expectEqual(lpm_mode.Mode.active, fix.unit.state().?);
    try std.testing.expectEqual(@as(u32, 3), fix.unit.stores);
    try std.testing.expectEqual(@as(u32, 0), fix.unit.standby_selects);
}

test "only OPE is software-writable in SBYCR" {
    var fix: Fixture = undefined;
    fix.init();
    fix.unlock();
    fix.store(lpm.index.sbycr, 0xFF);
    try std.testing.expectEqual(@as(u32, 0x40), fix.load(lpm.index.sbycr));
    try std.testing.expect(fix.unit.busOutputKept());
    fix.store(lpm.index.sbycr, 0x00);
    try std.testing.expectEqual(@as(u32, 0x00), fix.load(lpm.index.sbycr));
    try std.testing.expect(!fix.unit.busOutputKept());
}

test "DPSBYCR keeps IOKEEP and DCSSMODE, and bit 4 reads back regardless" {
    var fix: Fixture = undefined;
    fix.init();
    fix.unlock();
    fix.store(lpm.index.dpsbycr, 0x00);
    try std.testing.expectEqual(@as(u32, 0x10), fix.load(lpm.index.dpsbycr));
    fix.store(lpm.index.dpsbycr, 0xFF);
    try std.testing.expectEqual(@as(u32, 0x5C), fix.load(lpm.index.dpsbycr));
    try std.testing.expect(fix.unit.ioKept());
    try std.testing.expectEqual(lpm_mode.SoftStart.us_512, fix.unit.softStart());
}

test "DCSSMODE 0 is counted as prohibited rather than refused" {
    var fix: Fixture = undefined;
    fix.init();
    fix.unlock();
    fix.store(lpm.index.dpsbycr, 0x40);
    try std.testing.expectEqual(lpm_mode.SoftStart.prohibited, fix.unit.softStart());
    try std.testing.expectEqual(@as(u32, 1), fix.unit.prohibited_softstart);
    try std.testing.expectEqual(@as(u32, 1), fix.unit.stores);
}

test "an undefined LPMD code is kept, counted, and has no state" {
    var fix: Fixture = undefined;
    fix.init();
    fix.unlock();
    fix.store(lpm.index.lpscr, 0x7);
    try std.testing.expectEqual(@as(u32, 0x7), fix.load(lpm.index.lpscr));
    try std.testing.expect(fix.unit.state() == null);
    try std.testing.expectEqual(@as(u32, 1), fix.unit.undefined_modes);
    try std.testing.expectEqual(@as(u32, 0), fix.unit.standby_selects);
}

test "selecting a state deeper than sleep is counted" {
    var fix: Fixture = undefined;
    fix.init();
    fix.unlock();
    fix.store(lpm.index.lpscr, 0x5);
    fix.store(lpm.index.lpscr, 0xA);
    try std.testing.expectEqual(lpm_mode.Mode.deep_standby_3, fix.unit.state().?);
    try std.testing.expectEqual(@as(u32, 2), fix.unit.standby_selects);
}

test "LPSCR keeps only LPMD" {
    var fix: Fixture = undefined;
    fix.init();
    fix.unlock();
    fix.store(lpm.index.lpscr, 0xF5);
    try std.testing.expectEqual(@as(u32, 0x5), fix.load(lpm.index.lpscr));
}

test "each register answers at its own address and nowhere else" {
    try std.testing.expectEqual(lpm.index.sbycr, lpm.indexOf(0x4001_E00C).?);
    try std.testing.expectEqual(lpm.index.dpsbycr, lpm.indexOf(0x4001_EA00).?);
    try std.testing.expectEqual(lpm.index.lpscr, lpm.indexOf(0x4001_EA90).?);
    try std.testing.expectEqual(lpm.index.sscr1, lpm.indexOf(0x4001_EA98).?);
    try std.testing.expect(lpm.indexOf(0x4001_EA99) == null);
    try std.testing.expect(lpm.indexOf(0x4001_E00D) == null);
}

test "one bus window per register, a byte wide" {
    var fix: Fixture = undefined;
    fix.init();
    for (0..lpm.slots.len) |which| {
        const one = fix.unit.block(which);
        try std.testing.expectEqual(lpm.slots[which].address, one.base);
        try std.testing.expectEqual(@as(u32, 1), one.size);
    }
}

test "the group these sit behind is PRC1, not PRC0" {
    try std.testing.expectEqual(prcr.group.lpm, lpm.guard);
    var fix: Fixture = undefined;
    fix.init();
    fix.protection.write(prcr.win_base, 2, prcr.unlockWord(prcr.group.cgc));
    fix.store(lpm.index.lpscr, 0x5);
    try std.testing.expectEqual(@as(u32, 1), fix.unit.dropped_locked);
}

test "SSCR1 reads its cold-reset value of zero" {
    var fix: Fixture = undefined;
    fix.init();
    try std.testing.expectEqual(@as(u32, 0x00), fix.load(lpm.index.sscr1));
    try std.testing.expect(!fix.unit.fastReturn());
    try std.testing.expectEqual(@as(u2, 0), fix.unit.standbyLowPower());
}

test "SSCR1 sits at 0x4001_EA98 in its own one-byte window" {
    try std.testing.expectEqual(@as(?usize, lpm.index.sscr1), lpm.indexOf(0x4001_EA98));
    var fix: Fixture = undefined;
    fix.init();
    const window = fix.unit.block(lpm.index.sscr1);
    try std.testing.expectEqual(@as(u32, 0x4001_EA98), window.base);
    try std.testing.expectEqual(@as(u32, 1), window.size);
}

test "SSCR1 keeps SS2FR and SS2LP and reads the other bits as zero" {
    var fix: Fixture = undefined;
    fix.init();
    fix.unlock();
    fix.store(lpm.index.sscr1, 0xFF);
    try std.testing.expectEqual(@as(u32, 0x0D), fix.load(lpm.index.sscr1));
    try std.testing.expect(fix.unit.fastReturn());
    try std.testing.expectEqual(@as(u2, 3), fix.unit.standbyLowPower());
}

test "SSCR1 takes what ra8_lpm_init packs: SS2LP 1 with fast return" {
    var fix: Fixture = undefined;
    fix.init();
    fix.unlock();
    fix.store(lpm.index.sscr1, (1 << lpm.field.ss2lp_shift) | lpm.field.ss2fr);
    try std.testing.expectEqual(@as(u32, 0x05), fix.load(lpm.index.sscr1));
    fix.store(lpm.index.sscr1, 0);
    try std.testing.expectEqual(@as(u32, 0x00), fix.load(lpm.index.sscr1));
    try std.testing.expectEqual(@as(u32, 2), fix.unit.stores);
}

test "an SSCR1 store with PRC1 locked is dropped and counted" {
    var fix: Fixture = undefined;
    fix.init();
    fix.store(lpm.index.sscr1, 0x0D);
    try std.testing.expectEqual(@as(u32, 0x00), fix.load(lpm.index.sscr1));
    try std.testing.expectEqual(@as(u32, 1), fix.unit.dropped_locked);
}
