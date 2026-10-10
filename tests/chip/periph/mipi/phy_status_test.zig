//! The DPHYSFR rule: what latches each flag, and what does not.
const std = @import("std");
const ra8 = @import("ra8");

const status = ra8.chip.periph.mipi.phy_status;

test "an unpowered PHY reports nothing" {
    try std.testing.expectEqual(@as(u32, 0), status.value(0, 0, 0));
}

test "PWRSF latches on PWRCR.PWRSEN" {
    const sfr = status.value(status.power.pwrsen, status.pll_control.pllstp, 0);
    try std.testing.expectEqual(status.flag.pwrsf, sfr);
}

test "PLLSF needs the LDO up, a multiplier, and PLLSTP clear" {
    const configured: u32 = 0x0002_1000;
    try std.testing.expectEqual(
        status.flag.ready,
        status.value(status.power.pwrsen, 0, configured),
    );
}

test "a stopped PLL does not lock" {
    const sfr = status.value(status.power.pwrsen, status.pll_control.pllstp, 0x0002_1000);
    try std.testing.expectEqual(status.flag.pwrsf, sfr);
}

test "an unconfigured PLL does not lock, which is CSI device mode" {
    const sfr = status.value(status.power.pwrsen, 0, 0);
    try std.testing.expectEqual(status.flag.pwrsf, sfr);
}

test "the PLL cannot lock before the LDO is up" {
    try std.testing.expectEqual(@as(u32, 0), status.value(0, 0, 0x0002_1000));
}

test "ready is both flags, never one" {
    try std.testing.expect(status.ready(status.flag.ready));
    try std.testing.expect(!status.ready(status.flag.pwrsf));
    try std.testing.expect(!status.ready(status.flag.pllsf));
}

test "the mode comes from DPHYMDC bit 0" {
    try std.testing.expectEqual(status.Mode.device, status.Mode.of(0));
    try std.testing.expectEqual(status.Mode.host, status.Mode.of(status.mode_control.hosten));
}

test "PLLSTP set stops the PLL" {
    try std.testing.expect(status.running(0));
    try std.testing.expect(!status.running(status.pll_control.pllstp));
}

test "DPHYOCR.DPHYEN is what drives the lanes" {
    try std.testing.expect(!status.enabled(0));
    try std.testing.expect(status.enabled(status.operation.dphyen));
}

test "describe names the three states the report cares about" {
    try std.testing.expectEqualStrings("LDO off", status.describe(0));
    try std.testing.expectEqualStrings(
        "LDO stable, PLL not locked",
        status.describe(status.flag.pwrsf),
    );
    try std.testing.expectEqualStrings(
        "LDO stable, PLL locked",
        status.describe(status.flag.ready),
    );
}
