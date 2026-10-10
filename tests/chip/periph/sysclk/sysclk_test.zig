const std = @import("std");
const ra8 = @import("ra8");
const sysclk = ra8.chip.periph.sysclk;
const sysclk_div = ra8.chip.periph.sysclk_div;
const prcr = ra8.chip.periph.prcr;
const oscsf = ra8.chip.periph.oscsf;
const vscr = ra8.chip.periph.vscr;
const hazard = ra8.chip.periph.voltage_hazard;

/// A tree with its own protection and oscillators, the way the board builds
/// one. Both have to outlive the tree, so the fixture owns all three.
const Fixture = struct {
    protection: prcr.Prcr,
    oscillators: oscsf.Oscillators,
    voltage: vscr.Unit,
    brownout: hazard.Watch,
    tree: sysclk.Tree,

    fn init(self: *Fixture) void {
        self.protection = prcr.Prcr.init();
        self.oscillators = oscsf.Oscillators.init(&self.protection);
        self.voltage = vscr.Unit.init(&self.protection);
        self.brownout = hazard.Watch.init(&self.voltage);
        self.tree = sysclk.Tree.init(&self.protection, &self.oscillators, &self.brownout);
    }

    /// Open PRC0, the way RA8_PROTECTED_WRITE(k_ra8_prcr_unlock_cgc) does.
    fn unlock(self: *Fixture) void {
        self.protection.write(prcr.win_base, 2, prcr.unlockWord(prcr.group.cgc));
    }

    fn lock(self: *Fixture) void {
        self.protection.write(prcr.win_base, 2, prcr.unlockWord(0));
    }

    /// Start a source by clearing its stop bit, PRC0 open.
    fn start(self: *Fixture, control: u32) void {
        self.unlock();
        self.oscillators.write(oscsf.win_base + control, 1, 0);
    }

    fn at(offset: u32) u32 {
        return sysclk.win_base + offset;
    }
};

test "the tree starts on HOCO, which is the reset value SCKSCR reads" {
    var fix: Fixture = undefined;
    fix.init();
    try std.testing.expectEqual(sysclk.Source.hoco, fix.tree.source());
    try std.testing.expect(fix.tree.quiet());
}

test "a divider word written with PRC0 open lands and reads back" {
    var fix: Fixture = undefined;
    fix.init();
    fix.unlock();
    fix.tree.write(Fixture.at(sysclk.regs.sckdivcr), 4, 0x3223_3432);
    try std.testing.expectEqual(@as(u32, 0x3223_3432), fix.tree.read(Fixture.at(sysclk.regs.sckdivcr), 4));
    fix.tree.write(Fixture.at(sysclk.regs.sckdivcr2), 2, 0x2020);
    try std.testing.expectEqual(@as(u32, 0x2020), fix.tree.read(Fixture.at(sysclk.regs.sckdivcr2), 2));
}

test "a divider word written with PRC0 shut goes nowhere and is counted" {
    var fix: Fixture = undefined;
    fix.init();
    fix.tree.write(Fixture.at(sysclk.regs.sckdivcr), 4, 0x3223_3432);
    try std.testing.expectEqual(@as(u32, 0), fix.tree.read(Fixture.at(sysclk.regs.sckdivcr), 4));
    try std.testing.expectEqual(@as(u32, 1), fix.tree.dropped_locked);
    try std.testing.expectEqual(@as(u32, 0), fix.tree.programmed);
}

test "a source select with PRC0 shut leaves the tree where it was" {
    var fix: Fixture = undefined;
    fix.init();
    fix.tree.write(Fixture.at(sysclk.regs.sckscr), 1, @backingInt(sysclk.Source.pll1));
    try std.testing.expectEqual(sysclk.Source.hoco, fix.tree.source());
    try std.testing.expectEqual(@as(u32, 1), fix.tree.dropped_locked);
    try std.testing.expectEqual(@as(u32, 0), fix.tree.selects);
}

test "unlocking then locking again shuts the gate behind it" {
    var fix: Fixture = undefined;
    fix.init();
    fix.unlock();
    fix.tree.write(Fixture.at(sysclk.regs.sckdivcr), 4, 0x1111_1111);
    fix.lock();
    fix.tree.write(Fixture.at(sysclk.regs.sckdivcr), 4, 0x2222_2222);
    try std.testing.expectEqual(@as(u32, 0x1111_1111), fix.tree.read(Fixture.at(sysclk.regs.sckdivcr), 4));
    try std.testing.expectEqual(@as(u32, 1), fix.tree.dropped_locked);
}

test "selecting a stabilised source is not remarked on" {
    var fix: Fixture = undefined;
    fix.init();
    // PLL1 comes up stopped; start it and let OSCSF raise PLL1SF.
    fix.start(oscsf.regs.pllcr);
    try std.testing.expect(fix.oscillators.running(oscsf.flag.pll1sf));
    fix.tree.write(Fixture.at(sysclk.regs.sckscr), 1, @backingInt(sysclk.Source.pll1));
    try std.testing.expectEqual(sysclk.Source.pll1, fix.tree.source());
    try std.testing.expectEqual(@as(u32, 1), fix.tree.selects);
    try std.testing.expectEqual(@as(u32, 0), fix.tree.unstable_selects);
}

test "selecting a source that never stabilised lands, and is counted" {
    var fix: Fixture = undefined;
    fix.init();
    fix.unlock();
    // PLL1 is still stopped, so PLL1SF is down and the driver skipped its wait.
    fix.tree.write(Fixture.at(sysclk.regs.sckscr), 1, @backingInt(sysclk.Source.pll1));
    try std.testing.expectEqual(sysclk.Source.pll1, fix.tree.source());
    try std.testing.expectEqual(@as(u32, 1), fix.tree.unstable_selects);
}

test "a source with no OSCSF flag is selected without comment" {
    var fix: Fixture = undefined;
    fix.init();
    fix.unlock();
    fix.tree.write(Fixture.at(sysclk.regs.sckscr), 1, @backingInt(sysclk.Source.moco));
    try std.testing.expectEqual(sysclk.Source.moco, fix.tree.source());
    try std.testing.expectEqual(@as(u32, 0), fix.tree.unstable_selects);
    try std.testing.expectEqual(@as(u32, 0), fix.tree.reserved_selects);
}

test "CKSEL 7 is not a source ra8_cksel_t defines" {
    var fix: Fixture = undefined;
    fix.init();
    fix.unlock();
    fix.tree.write(Fixture.at(sysclk.regs.sckscr), 1, 7);
    try std.testing.expectEqual(sysclk.Source.reserved, fix.tree.source());
    try std.testing.expectEqual(@as(u32, 1), fix.tree.reserved_selects);
    try std.testing.expectEqual(@as(u32, 0), fix.tree.unstable_selects);
}

test "the bits above CKSEL are reserved and read zero" {
    var fix: Fixture = undefined;
    fix.init();
    fix.unlock();
    fix.tree.write(Fixture.at(sysclk.regs.sckscr), 1, 0xF5);
    try std.testing.expectEqual(@as(u32, 5), fix.tree.read(Fixture.at(sysclk.regs.sckscr), 1));
    try std.testing.expectEqual(sysclk.Source.pll1, fix.tree.source());
}

test "a byte store merges into the divider word it names" {
    var fix: Fixture = undefined;
    fix.init();
    fix.unlock();
    fix.tree.write(Fixture.at(sysclk.regs.sckdivcr), 4, 0x0000_0000);
    fix.tree.write(Fixture.at(sysclk.regs.sckdivcr) + 3, 1, 0x32);
    try std.testing.expectEqual(@as(u32, 0x3200_0000), fix.tree.read(Fixture.at(sysclk.regs.sckdivcr), 4));
}

test "the decoded tree is the one the bring-up driver programmed" {
    var fix: Fixture = undefined;
    fix.init();
    fix.unlock();
    fix.tree.write(Fixture.at(sysclk.regs.sckdivcr), 4, 0x3223_3432);
    fix.tree.write(Fixture.at(sysclk.regs.sckdivcr2), 2, 0x2020);
    try std.testing.expectEqual(@as(?u32, 4), fix.tree.ratioOf(sysclk_div.domains[1]));
    try std.testing.expectEqual(@as(?u32, 1), fix.tree.ratioOf2(sysclk_div.domains2[0]));
}

test "the window answers only its own three registers" {
    var fix: Fixture = undefined;
    fix.init();
    try std.testing.expectEqual(@as(u32, 0x7), sysclk.win_span);
    try std.testing.expectEqual(@as(u32, 0x4001_E020), sysclk.win_base);
    // The byte above SCKSCR is outside the window and answers zero.
    try std.testing.expectEqual(@as(u32, 0), fix.tree.read(Fixture.at(sysclk.win_span), 1));
}

const rate = sysclk.rate;

/// The EK-RA8D2 quickstart PLL1: XTAL 24 MHz, /3 in, x250.00, P /2.
const quickstart_pll1 = rate.PllConfig{ .ccr = 0xFA02, .ccr2 = 0x451 };

test "the quickstart PLL1 with the bring-up dividers runs CPU0 at 1 GHz and CPU1 at 250 MHz" {
    const inputs = rate.Inputs{ .source = .pll1, .divcr2 = 0x2020, .pll1 = quickstart_pll1, .pll2 = .{} };
    try std.testing.expectEqual(@as(?u64, 1_000_000_000), rate.pllP(quickstart_pll1));
    try std.testing.expectEqual(@as(?u64, 1_000_000_000), rate.coreHz(inputs, .cpu0));
    try std.testing.expectEqual(@as(?u64, 250_000_000), rate.coreHz(inputs, .cpu1));
}

test "out of reset the tree runs both cores on HOCO" {
    const inputs = rate.Inputs{ .source = .hoco, .divcr2 = 0, .pll1 = .{}, .pll2 = .{} };
    try std.testing.expectEqual(@as(?u64, 20_000_000), rate.coreHz(inputs, .cpu0));
    try std.testing.expectEqual(@as(?u64, 20_000_000), rate.coreHz(inputs, .cpu1));
}

test "a divider on MOCO and on the main oscillator divides the cited frequency" {
    const moco = rate.Inputs{ .source = .moco, .divcr2 = 0x0001, .pll1 = .{}, .pll2 = .{} };
    try std.testing.expectEqual(@as(?u64, 4_000_000), rate.coreHz(moco, .cpu0));
    const main = rate.Inputs{ .source = .main, .divcr2 = 0x0080, .pll1 = .{}, .pll2 = .{} };
    try std.testing.expectEqual(@as(?u64, 8_000_000), rate.coreHz(main, .cpu1));
}

test "an uncited source, an unconfigured PLL and a prohibited divider leave the rate unknown" {
    const loco = rate.Inputs{ .source = .loco, .divcr2 = 0, .pll1 = .{}, .pll2 = .{} };
    try std.testing.expectEqual(@as(?u64, null), rate.coreHz(loco, .cpu0));
    const bare = rate.Inputs{ .source = .pll2, .divcr2 = 0, .pll1 = quickstart_pll1, .pll2 = .{} };
    try std.testing.expectEqual(@as(?u64, null), rate.coreHz(bare, .cpu0));
    const prohibited = rate.Inputs{ .source = .hoco, .divcr2 = 0x0007, .pll1 = .{}, .pll2 = .{} };
    try std.testing.expectEqual(@as(?u64, null), rate.coreHz(prohibited, .cpu0));
}
