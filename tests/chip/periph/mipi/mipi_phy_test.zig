//! The D-PHY window: the poll the driver spins on, and the store it must not
//! be allowed to make.
const std = @import("std");
const ra8 = @import("ra8");

const mipi_phy = ra8.chip.periph.mipi_phy;
const status = ra8.chip.periph.mipi_phy_status;

fn at(offset: u32) u32 {
    return mipi_phy.win_base + offset;
}

/// Steps 1-5 of ra8_mipi_phy_init: mode, refclk, LDO, then wait on PWRSF.
fn powerUp(phy: *mipi_phy.MipiPhy) void {
    phy.write(at(mipi_phy.off.mdc), 4, status.mode_control.hosten);
    phy.write(at(mipi_phy.off.refcr), 4, 249);
    phy.write(at(mipi_phy.off.pwrcr), 4, status.power.pwrsen);
}

test "a fresh PHY reads DPHYSFR as zero and stays quiet" {
    var phy = mipi_phy.MipiPhy.init();
    try std.testing.expectEqual(@as(u32, 0), phy.read(at(mipi_phy.off.sfr), 4));
    try std.testing.expect(!phy.quiet());
}

test "the LDO wait ends once PWRSEN is written" {
    var phy = mipi_phy.MipiPhy.init();
    powerUp(&phy);
    try std.testing.expectEqual(status.flag.pwrsf, phy.read(at(mipi_phy.off.sfr), 4));
    try std.testing.expectEqual(@as(u32, 1), phy.powerups);
    try std.testing.expectEqual(@as(u32, 1), phy.polls);
}

test "the host init sequence reaches ready, which is what the driver waits for" {
    var phy = mipi_phy.MipiPhy.init();
    powerUp(&phy);
    phy.write(at(mipi_phy.off.plfcr), 4, 0x0002_1000);
    phy.write(at(mipi_phy.off.esccr), 4, 0x0000_0004);
    phy.write(at(mipi_phy.off.plocr), 4, 0);
    try std.testing.expectEqual(status.flag.ready, phy.read(at(mipi_phy.off.sfr), 4));
    try std.testing.expect(phy.ready());
    try std.testing.expectEqual(@as(u32, 1), phy.locks);
}

test "CSI device mode powers up and never claims a lock" {
    var phy = mipi_phy.MipiPhy.init();
    phy.write(at(mipi_phy.off.mdc), 4, 0);
    phy.write(at(mipi_phy.off.pwrcr), 4, status.power.pwrsen);
    phy.write(at(mipi_phy.off.plfcr), 4, 0);
    phy.write(at(mipi_phy.off.plocr), 4, 0);
    try std.testing.expectEqual(status.flag.pwrsf, phy.read(at(mipi_phy.off.sfr), 4));
    try std.testing.expectEqual(status.Mode.device, phy.mode());
    try std.testing.expectEqual(@as(u32, 0), phy.locks);
}

test "deinit drops both flags again" {
    var phy = mipi_phy.MipiPhy.init();
    powerUp(&phy);
    phy.write(at(mipi_phy.off.plfcr), 4, 0x0002_1000);
    phy.write(at(mipi_phy.off.plocr), 4, 0);
    try std.testing.expect(phy.ready());
    phy.write(at(mipi_phy.off.ocr), 4, 0);
    phy.write(at(mipi_phy.off.plocr), 4, status.pll_control.pllstp);
    phy.write(at(mipi_phy.off.pwrcr), 4, 0);
    try std.testing.expectEqual(@as(u32, 0), phy.read(at(mipi_phy.off.sfr), 4));
}

test "a store to DPHYSFR is refused, not kept" {
    var phy = mipi_phy.MipiPhy.init();
    phy.write(at(mipi_phy.off.sfr), 4, status.flag.ready);
    try std.testing.expectEqual(@as(u32, 1), phy.refused);
    try std.testing.expectEqual(@as(u32, 0), phy.read(at(mipi_phy.off.sfr), 4));
}

test "a read that finds nothing latched is counted apart from one that does" {
    var phy = mipi_phy.MipiPhy.init();
    _ = phy.read(at(mipi_phy.off.sfr), 4);
    _ = phy.read(at(mipi_phy.off.sfr), 4);
    try std.testing.expectEqual(@as(u32, 2), phy.dark_polls);
    phy.write(at(mipi_phy.off.pwrcr), 4, status.power.pwrsen);
    _ = phy.read(at(mipi_phy.off.sfr), 4);
    try std.testing.expectEqual(@as(u32, 1), phy.polls);
}

test "powering the LDO twice over counts one power-up per edge" {
    var phy = mipi_phy.MipiPhy.init();
    phy.write(at(mipi_phy.off.pwrcr), 4, status.power.pwrsen);
    phy.write(at(mipi_phy.off.pwrcr), 4, status.power.pwrsen);
    try std.testing.expectEqual(@as(u32, 1), phy.powerups);
    phy.write(at(mipi_phy.off.pwrcr), 4, 0);
    phy.write(at(mipi_phy.off.pwrcr), 4, status.power.pwrsen);
    try std.testing.expectEqual(@as(u32, 2), phy.powerups);
}

test "DPHYEN is counted on its rising edge" {
    var phy = mipi_phy.MipiPhy.init();
    phy.write(at(mipi_phy.off.ocr), 4, status.operation.dphyen);
    phy.write(at(mipi_phy.off.ocr), 4, status.operation.dphyen);
    try std.testing.expectEqual(@as(u32, 1), phy.enables);
    try std.testing.expect(phy.driving());
}

test "the timing registers read back what was written" {
    var phy = mipi_phy.MipiPhy.init();
    phy.write(at(mipi_phy.off.tim1), 4, 0x0007_FFFF);
    phy.write(at(mipi_phy.off.tim6), 4, 0x0000_0012);
    try std.testing.expectEqual(@as(u32, 0x0007_FFFF), phy.read(at(mipi_phy.off.tim1), 4));
    try std.testing.expectEqual(@as(u32, 0x0000_0012), phy.read(at(mipi_phy.off.tim6), 4));
}

test "RFREQ encodes MHz minus one" {
    var phy = mipi_phy.MipiPhy.init();
    phy.write(at(mipi_phy.off.refcr), 4, 249);
    try std.testing.expectEqual(@as(u32, 250), phy.referenceMhz());
}

test "a byte store lands in its word without counting a status poll" {
    var phy = mipi_phy.MipiPhy.init();
    phy.write(at(mipi_phy.off.refcr), 1, 0xF9);
    try std.testing.expectEqual(@as(u32, 0xF9), phy.read(at(mipi_phy.off.refcr), 4));
    try std.testing.expectEqual(@as(u32, 0xF9), phy.read(at(mipi_phy.off.refcr), 1));
    try std.testing.expectEqual(@as(u32, 0), phy.polls);
}

test "an address past the window answers zero and changes nothing" {
    var phy = mipi_phy.MipiPhy.init();
    phy.write(mipi_phy.win_base + mipi_phy.win_span, 4, 0xFFFF_FFFF);
    try std.testing.expectEqual(@as(u32, 0), phy.read(mipi_phy.win_base + mipi_phy.win_span, 4));
    try std.testing.expect(phy.quiet());
}

test "an unnamed word in the window survives a read-modify-write" {
    var phy = mipi_phy.MipiPhy.init();
    phy.write(at(0x03C), 4, 0xDEAD_BEEF);
    try std.testing.expectEqual(@as(u32, 0xDEAD_BEEF), phy.read(at(0x03C), 4));
}

test "the block answers on its own window" {
    var phy = mipi_phy.MipiPhy.init();
    const window = phy.block();
    try std.testing.expectEqual(mipi_phy.win_base, window.base);
    try std.testing.expectEqual(mipi_phy.win_span, window.size);
    window.writeFn(window.context, at(mipi_phy.off.pwrcr), 4, status.power.pwrsen);
    try std.testing.expectEqual(
        status.flag.pwrsf,
        window.readFn(window.context, at(mipi_phy.off.sfr), 4),
    );
}

test "enabling the lanes before the flags are up is counted apart" {
    var phy = mipi_phy.MipiPhy.init();
    phy.write(at(mipi_phy.off.ocr), 4, status.operation.dphyen);
    try std.testing.expectEqual(@as(u32, 1), phy.early_enables);
    phy.write(at(mipi_phy.off.ocr), 4, 0);
    powerUp(&phy);
    phy.write(at(mipi_phy.off.plfcr), 4, 0x0002_1000);
    // ra8_mipi_phy_init releases the PLL and waits on PLLSF before step 11
    // enables the lanes. Without that release the PLL is still stopped, so
    // this enable would be early too.
    phy.write(at(mipi_phy.off.plocr), 4, 0);
    phy.write(at(mipi_phy.off.ocr), 4, status.operation.dphyen);
    try std.testing.expectEqual(@as(u32, 2), phy.enables);
    try std.testing.expectEqual(@as(u32, 1), phy.early_enables);
}

test "DPHYPLOCR reads the PLL stopped out of reset" {
    var phy = mipi_phy.MipiPhy.init();
    try std.testing.expectEqual(
        status.pll_control.pllstp,
        phy.read(at(mipi_phy.off.plocr), 4),
    );
    try std.testing.expect(!status.running(phy.read(at(mipi_phy.off.plocr), 4)));
}

test "the lock flag comes up on the write that releases the PLL, not on the coefficients" {
    var phy = mipi_phy.MipiPhy.init();
    powerUp(&phy);
    phy.write(at(mipi_phy.off.plfcr), 4, 0x0002_1000);
    try std.testing.expectEqual(status.flag.pwrsf, phy.read(at(mipi_phy.off.sfr), 4));
    try std.testing.expectEqual(@as(u32, 0), phy.locks);
    phy.write(at(mipi_phy.off.plocr), 4, 0);
    try std.testing.expectEqual(status.flag.ready, phy.read(at(mipi_phy.off.sfr), 4));
    try std.testing.expectEqual(@as(u32, 1), phy.locks);
}

test "DPHYPLFCR is ignored while the PLL is running" {
    var phy = mipi_phy.MipiPhy.init();
    powerUp(&phy);
    phy.write(at(mipi_phy.off.plfcr), 4, 0x0002_1000);
    phy.write(at(mipi_phy.off.plocr), 4, 0);
    phy.write(at(mipi_phy.off.plfcr), 4, 0x0003_2000);
    try std.testing.expectEqual(@as(u32, 0x0002_1000), phy.read(at(mipi_phy.off.plfcr), 4));
    try std.testing.expectEqual(@as(u32, 1), phy.pll.ignored);
}

test "DPHYESCCR is ignored while the PLL is running" {
    var phy = mipi_phy.MipiPhy.init();
    powerUp(&phy);
    phy.write(at(mipi_phy.off.esccr), 4, 0x0000_0004);
    phy.write(at(mipi_phy.off.plfcr), 4, 0x0002_1000);
    phy.write(at(mipi_phy.off.plocr), 4, 0);
    phy.write(at(mipi_phy.off.esccr), 4, 0x0000_0010);
    try std.testing.expectEqual(@as(u32, 0x0000_0004), phy.read(at(mipi_phy.off.esccr), 4));
    try std.testing.expectEqual(@as(u32, 1), phy.pll.ignored);
}

test "the driver's set_lane_speed order lands, because it stops the PLL first" {
    var phy = mipi_phy.MipiPhy.init();
    powerUp(&phy);
    phy.write(at(mipi_phy.off.plfcr), 4, 0x0002_1000);
    phy.write(at(mipi_phy.off.plocr), 4, 0);
    phy.write(at(mipi_phy.off.plocr), 4, status.pll_control.pllstp);
    phy.write(at(mipi_phy.off.plfcr), 4, 0x0003_2000);
    phy.write(at(mipi_phy.off.plocr), 4, 0);
    try std.testing.expectEqual(@as(u32, 0x0003_2000), phy.read(at(mipi_phy.off.plfcr), 4));
    try std.testing.expectEqual(@as(u32, 0), phy.pll.ignored);
    try std.testing.expectEqual(@as(u32, 2), phy.locks);
}

test "a refused coefficient store makes the run loud" {
    var phy = mipi_phy.MipiPhy.init();
    phy.write(at(mipi_phy.off.plocr), 4, 0);
    phy.write(at(mipi_phy.off.esccr), 4, 0x0000_0010);
    try std.testing.expect(!phy.quiet());
    try std.testing.expectEqual(@as(u32, 1), phy.pll.ignored);
}
