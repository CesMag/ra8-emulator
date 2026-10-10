const std = @import("std");
const ra8 = @import("ra8");
const pll = ra8.chip.periph.pll;
const pll_div = ra8.chip.periph.pll.div;
const prcr = ra8.chip.periph.prcr;
const oscsf = ra8.chip.periph.oscsf;

const Fixture = struct {
    protection: prcr.Prcr,
    oscillators: oscsf.Oscillators,
    unit: pll.Unit,

    fn init(self: *Fixture) void {
        self.protection = prcr.Prcr.init();
        self.oscillators = oscsf.Oscillators.init(&self.protection);
        self.unit = pll.Unit.init(&self.protection, &self.oscillators);
    }

    /// Both PLLs come up stopped, so a barrier is open until something starts
    /// one. These are what internal_stop_pll1 and step 5 write.
    fn startPll1(self: *Fixture) void {
        self.oscillators.write(oscsf.win_base + oscsf.regs.pllcr, 1, 0);
    }

    fn stopPll1(self: *Fixture) void {
        self.oscillators.write(oscsf.win_base + oscsf.regs.pllcr, 1, oscsf.stop);
    }

    /// What internal_pll2_program_protected writes around its own pair.
    fn startPll2(self: *Fixture) void {
        self.oscillators.write(oscsf.win_base + oscsf.regs.pll2cr, 1, 0);
    }

    fn stopPll2(self: *Fixture) void {
        self.oscillators.write(oscsf.win_base + oscsf.regs.pll2cr, 1, oscsf.stop);
    }

    fn unlock(self: *Fixture) void {
        self.protection.write(prcr.win_base, 2, prcr.unlockWord(pll.guard));
    }

    fn relock(self: *Fixture) void {
        self.protection.write(prcr.win_base, 2, prcr.unlockWord(0));
    }

    fn store(self: *Fixture, which: usize, width: u3, value: u32) void {
        self.unit.write(pll.slots[which].address, width, value);
    }

    /// What internal_program_and_start_pll1 writes, in its own order.
    fn programQuickstart(self: *Fixture) void {
        self.store(pll.index.pllccr, 4, 0xFA02);
        self.store(pll.index.pllccr2, 2, 0x451);
    }

    /// What ra8_cgc_pll2_enable computes for the USB path: x40 on the main
    /// oscillator with /2 in, P = /4 and Q and R pinned at /6 so no field
    /// carries the prohibited code.
    fn programUsb(self: *Fixture) void {
        self.store(pll.index.pll2ccr, 4, (@as(u32, 40 * 4) << 6) | 1);
        self.store(pll.index.pll2ccr2, 2, (5 << 8) | (5 << 4) | 3);
    }
};

test "nothing is configured before firmware writes" {
    var fix: Fixture = undefined;
    fix.init();
    try std.testing.expect(fix.unit.quiet());
    try std.testing.expect(!fix.unit.pll1.configured());
    try std.testing.expect(!fix.unit.pll2.configured());
}

test "a store with PRC0 locked is dropped and counted" {
    var fix: Fixture = undefined;
    fix.init();
    fix.programQuickstart();
    fix.store(pll.index.moscwtcr, 1, 9);
    try std.testing.expectEqual(@as(u32, 3), fix.unit.dropped_locked);
    try std.testing.expectEqual(@as(u32, 0), fix.unit.pll1.stores);
    try std.testing.expect(!fix.unit.pll1.configured());
}

test "the quickstart programming lands once PRC0 is open" {
    var fix: Fixture = undefined;
    fix.init();
    fix.unlock();
    fix.programQuickstart();
    try std.testing.expectEqual(@as(u32, 0xFA02), fix.unit.read(0x4001_E0AC, 4));
    try std.testing.expectEqual(@as(u32, 0x451), fix.unit.read(0x4001_E04C, 2));
    try std.testing.expectEqual(pll_div.Source.main, fix.unit.pll1.source());
    try std.testing.expectEqual(@as(u8, 3), fix.unit.pll1.inputRatio().?);
    try std.testing.expectEqual(@as(u16, 250), fix.unit.pll1.multiplier().whole());
    const outputs = fix.unit.pll1.outputRatios();
    try std.testing.expectEqual(@as(u8, 2), outputs[0].?);
    try std.testing.expectEqual(@as(u8, 6), outputs[1].?);
    try std.testing.expectEqual(@as(u8, 5), outputs[2].?);
}

test "a PLLCCR2 store carrying a prohibited code is rejected whole" {
    var fix: Fixture = undefined;
    fix.init();
    fix.unlock();
    fix.programQuickstart();
    // P field back to the prohibited 0, everything else valid.
    fix.unit.write(0x4001_E04C, 2, 0x450);
    try std.testing.expectEqual(@as(u32, 0x451), fix.unit.read(0x4001_E04C, 2));
    try std.testing.expectEqual(@as(u32, 1), fix.unit.pll1.prohibited_divider);
    try std.testing.expectEqual(@as(u32, 2), fix.unit.pll1.stores);
}

test "a rejected PLLCCR2 store leaves the earlier ratios standing" {
    var fix: Fixture = undefined;
    fix.init();
    fix.unlock();
    fix.programQuickstart();
    fix.unit.write(0x4001_E04C, 2, 0x000);
    const outputs = fix.unit.pll1.outputRatios();
    try std.testing.expectEqual(@as(u8, 2), outputs[0].?);
    try std.testing.expectEqual(@as(u8, 6), outputs[1].?);
    try std.testing.expectEqual(@as(u8, 5), outputs[2].?);
    try std.testing.expectEqual(@as(u32, 1), fix.unit.pll1.prohibited_divider);
}

test "every valid divider combination is accepted" {
    var fix: Fixture = undefined;
    fix.init();
    fix.unlock();
    const word: u16 = (15 << 8) | (8 << 4) | 7;
    fix.unit.write(0x4001_E04C, 2, word);
    const outputs = fix.unit.pll1.outputRatios();
    try std.testing.expectEqual(@as(u8, 8), outputs[0].?);
    try std.testing.expectEqual(@as(u8, 9), outputs[1].?);
    try std.testing.expectEqual(@as(u8, 16), outputs[2].?);
    try std.testing.expectEqual(@as(u32, 0), fix.unit.pll1.prohibited_divider);
}

test "PLLCCR takes the whole 32-bit word including the nine-bit multiplier" {
    var fix: Fixture = undefined;
    fix.init();
    fix.unlock();
    // The widest multiplier the field holds: 511 whole, no quarters.
    const word: u32 = (@as(u32, 511 * 4) << 6) | 0x10 | 1;
    fix.unit.write(0x4001_E0AC, 4, word);
    try std.testing.expectEqual(word, fix.unit.read(0x4001_E0AC, 4));
    try std.testing.expectEqual(@as(u16, 511), fix.unit.pll1.multiplier().whole());
    try std.testing.expectEqual(pll_div.Source.hoco, fix.unit.pll1.source());
    try std.testing.expectEqual(@as(u8, 2), fix.unit.pll1.inputRatio().?);
}

test "MOSCWTCR keeps the wait code the oscillator bring-up writes" {
    var fix: Fixture = undefined;
    fix.init();
    fix.unlock();
    fix.unit.write(0x4001_E0A2, 1, 9);
    try std.testing.expectEqual(@as(u32, 9), fix.unit.read(0x4001_E0A2, 1));
    try std.testing.expectEqual(@as(u8, 9), fix.unit.moscwtcr);
}

test "relocking PRC0 shuts every window again" {
    var fix: Fixture = undefined;
    fix.init();
    fix.unlock();
    fix.programQuickstart();
    fix.relock();
    fix.unit.write(0x4001_E0AC, 4, 0);
    fix.unit.write(0x4001_E04C, 2, 0x111);
    try std.testing.expectEqual(@as(u32, 0xFA02), fix.unit.read(0x4001_E0AC, 4));
    try std.testing.expectEqual(@as(u32, 0x451), fix.unit.read(0x4001_E04C, 2));
    try std.testing.expectEqual(@as(u32, 2), fix.unit.dropped_locked);
}

test "a byte load reads its own lane of the wider register" {
    var fix: Fixture = undefined;
    fix.init();
    fix.unlock();
    fix.unit.write(0x4001_E0AC, 4, 0xFA02);
    try std.testing.expectEqual(@as(u32, 0x02), fix.unit.read(0x4001_E0AC, 1));
    try std.testing.expectEqual(@as(u32, 0xFA), fix.unit.read(0x4001_E0AD, 1));
    try std.testing.expectEqual(@as(u32, 0xFA02), fix.unit.read(0x4001_E0AC, 2));
}

test "each register owns its own window and nothing between them" {
    try std.testing.expectEqual(pll.index.pllccr2, pll.indexOf(0x4001_E04C).?);
    try std.testing.expectEqual(pll.index.pllccr2, pll.indexOf(0x4001_E04D).?);
    try std.testing.expectEqual(pll.index.pll2ccr2, pll.indexOf(0x4001_E04E).?);
    try std.testing.expectEqual(pll.index.pll2ccr2, pll.indexOf(0x4001_E04F).?);
    try std.testing.expectEqual(pll.index.moscwtcr, pll.indexOf(0x4001_E0A2).?);
    try std.testing.expectEqual(pll.index.pllccr, pll.indexOf(0x4001_E0AF).?);
    try std.testing.expectEqual(pll.index.pll2ccr, pll.indexOf(0x4001_E0CB).?);
    try std.testing.expect(pll.indexOf(0x4001_E050) == null);
    try std.testing.expect(pll.indexOf(0x4001_E0A3) == null);
    try std.testing.expect(pll.indexOf(0x4001_E0B0) == null);
    try std.testing.expect(pll.indexOf(0x4001_E0CC) == null);
}

test "the group these sit behind is PRC0, the same as the clock tree" {
    try std.testing.expectEqual(prcr.group.cgc, pll.guard);
    var fix: Fixture = undefined;
    fix.init();
    fix.protection.write(prcr.win_base, 2, prcr.unlockWord(prcr.group.lpm));
    fix.unit.write(0x4001_E0AC, 4, 0xFA02);
    try std.testing.expectEqual(@as(u32, 1), fix.unit.dropped_locked);
}

test "one bus window per register, at the documented widths" {
    var fix: Fixture = undefined;
    fix.init();
    const widths = [_]u32{ 2, 2, 1, 4, 4 };
    try std.testing.expectEqual(widths.len, pll.slots.len);
    for (0..pll.slots.len) |which| {
        const one = fix.unit.block(which);
        try std.testing.expectEqual(pll.slots[which].address, one.base);
        try std.testing.expectEqual(widths[which], one.size);
    }
}

test "PLL1 comes up stopped, so the configuration pair lands" {
    var fix: Fixture = undefined;
    fix.init();
    fix.unlock();
    try std.testing.expect(!fix.oscillators.running(oscsf.flag.pll1sf));
    fix.programQuickstart();
    try std.testing.expectEqual(@as(u32, 0xFA02), fix.unit.pll1.ccr);
    try std.testing.expectEqual(@as(u16, 0x451), fix.unit.pll1.ccr2);
    try std.testing.expectEqual(@as(u32, 0), fix.unit.pll1.dropped_running);
}

test "a PLLCCR store while PLL1 runs is dropped and counted" {
    var fix: Fixture = undefined;
    fix.init();
    fix.unlock();
    fix.startPll1();
    fix.store(pll.index.pllccr, 4, 0xFA02);
    try std.testing.expectEqual(@as(u32, 0), fix.unit.pll1.ccr);
    try std.testing.expectEqual(@as(u32, 1), fix.unit.pll1.dropped_running);
    try std.testing.expectEqual(@as(u32, 0), fix.unit.pll1.stores);
}

test "a PLLCCR2 store while PLL1 runs is dropped too" {
    var fix: Fixture = undefined;
    fix.init();
    fix.unlock();
    fix.startPll1();
    fix.store(pll.index.pllccr2, 2, 0x451);
    try std.testing.expectEqual(@as(u16, 0), fix.unit.pll1.ccr2);
    try std.testing.expectEqual(@as(u32, 1), fix.unit.pll1.dropped_running);
}

test "a dropped configuration store reads back as it was" {
    var fix: Fixture = undefined;
    fix.init();
    fix.unlock();
    fix.programQuickstart();
    fix.startPll1();
    fix.store(pll.index.pllccr, 4, 0x1234);
    try std.testing.expectEqual(
        @as(u32, 0xFA02),
        fix.unit.read(pll.slots[pll.index.pllccr].address, 4),
    );
}

test "MOSCWTCR is outside the barrier and lands while PLL1 runs" {
    var fix: Fixture = undefined;
    fix.init();
    fix.unlock();
    fix.startPll1();
    fix.store(pll.index.moscwtcr, 1, 9);
    try std.testing.expectEqual(@as(u8, 9), fix.unit.moscwtcr);
    try std.testing.expectEqual(@as(u32, 0), fix.unit.pll1.dropped_running);
    try std.testing.expectEqual(@as(u32, 1), fix.unit.wait_stores);
}

test "stopping PLL1 again reopens the barrier" {
    var fix: Fixture = undefined;
    fix.init();
    fix.unlock();
    fix.startPll1();
    fix.store(pll.index.pllccr, 4, 0xFA02);
    fix.stopPll1();
    fix.programQuickstart();
    try std.testing.expectEqual(@as(u32, 0xFA02), fix.unit.pll1.ccr);
    try std.testing.expectEqual(@as(u16, 0x451), fix.unit.pll1.ccr2);
    try std.testing.expectEqual(@as(u32, 1), fix.unit.pll1.dropped_running);
}

test "PRC0 is judged before the barrier" {
    var fix: Fixture = undefined;
    fix.init();
    fix.unlock();
    fix.startPll1();
    fix.relock();
    fix.store(pll.index.pllccr, 4, 0xFA02);
    try std.testing.expectEqual(@as(u32, 1), fix.unit.dropped_locked);
    try std.testing.expectEqual(@as(u32, 0), fix.unit.pll1.dropped_running);
}

test "the barrier alone breaks quiet" {
    var fix: Fixture = undefined;
    fix.init();
    fix.unlock();
    fix.startPll1();
    fix.store(pll.index.pllccr, 4, 0xFA02);
    try std.testing.expect(!fix.unit.quiet());
}

test "the USB path's PLL2 programming lands while PLL2 is stopped" {
    var fix: Fixture = undefined;
    fix.init();
    fix.unlock();
    try std.testing.expect(!fix.oscillators.running(oscsf.flag.pll2sf));
    fix.programUsb();
    try std.testing.expectEqual(pll_div.Source.main, fix.unit.pll2.source());
    try std.testing.expectEqual(@as(u8, 2), fix.unit.pll2.inputRatio().?);
    try std.testing.expectEqual(@as(u16, 40), fix.unit.pll2.multiplier().whole());
    const outputs = fix.unit.pll2.outputRatios();
    try std.testing.expectEqual(@as(u8, 4), outputs[0].?);
    try std.testing.expectEqual(@as(u8, 6), outputs[1].?);
    try std.testing.expectEqual(@as(u8, 6), outputs[2].?);
    try std.testing.expectEqual(@as(u32, 0), fix.unit.pll2.dropped_running);
}

test "a PLL2 configuration store while PLL2 runs is dropped and counted" {
    var fix: Fixture = undefined;
    fix.init();
    fix.unlock();
    fix.startPll2();
    fix.programUsb();
    try std.testing.expectEqual(@as(u32, 0), fix.unit.pll2.ccr);
    try std.testing.expectEqual(@as(u16, 0), fix.unit.pll2.ccr2);
    try std.testing.expectEqual(@as(u32, 2), fix.unit.pll2.dropped_running);
    try std.testing.expectEqual(@as(u32, 0), fix.unit.pll2.stores);
}

test "a PLL2CCR2 store carrying the prohibited code is rejected whole" {
    var fix: Fixture = undefined;
    fix.init();
    fix.unlock();
    fix.programUsb();
    // Q dropped to the prohibited 0, which is what pinning it at /6 avoids.
    fix.store(pll.index.pll2ccr2, 2, (5 << 8) | 3);
    try std.testing.expectEqual(
        @as(u32, (5 << 8) | (5 << 4) | 3),
        fix.unit.read(0x4001_E04E, 2),
    );
    try std.testing.expectEqual(@as(u32, 1), fix.unit.pll2.prohibited_divider);
}

test "the two PLLs keep their own words, barriers and counters" {
    var fix: Fixture = undefined;
    fix.init();
    fix.unlock();
    // PLL1 turning shuts only PLL1's barrier.
    fix.startPll1();
    fix.programQuickstart();
    fix.programUsb();
    try std.testing.expectEqual(@as(u32, 2), fix.unit.pll1.dropped_running);
    try std.testing.expectEqual(@as(u32, 0), fix.unit.pll2.dropped_running);
    try std.testing.expect(fix.unit.pll2.configured());
    try std.testing.expect(!fix.unit.pll1.configured());
    // And the reverse, once PLL1 stops and PLL2 starts.
    fix.stopPll1();
    fix.startPll2();
    fix.programQuickstart();
    fix.store(pll.index.pll2ccr, 4, 0);
    try std.testing.expectEqual(@as(u32, 0xFA02), fix.unit.pll1.ccr);
    try std.testing.expectEqual(@as(u32, 1), fix.unit.pll2.dropped_running);
}

test "each PLL watches its own OSCSF flag" {
    try std.testing.expectEqual(oscsf.flag.pll1sf, pll.barrierFlag(.pll1));
    try std.testing.expectEqual(oscsf.flag.pll2sf, pll.barrierFlag(.pll2));
}

test "PLL2 alone breaks quiet, and says nothing about PLL1" {
    var fix: Fixture = undefined;
    fix.init();
    fix.unlock();
    fix.programUsb();
    try std.testing.expect(!fix.unit.quiet());
    try std.testing.expect(fix.unit.pll1.quiet());
}
