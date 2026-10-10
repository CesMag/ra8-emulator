//! Covers src/chip/periph/mipi/mipi_phy_pll_lock.zig.
const std = @import("std");
const ra8 = @import("ra8");

const lock = ra8.chip.periph.mipi_phy_pll_lock;
const status = ra8.chip.periph.mipi_phy_status;

test "the PLL is stopped out of reset" {
    try std.testing.expectEqual(status.pll_control.pllstp, lock.plocr_reset);
    try std.testing.expect(!status.running(lock.plocr_reset));
}

test "a store carries while the PLL is stopped" {
    var gate = lock.Locked{};
    try std.testing.expect(gate.takes(status.pll_control.pllstp));
    try std.testing.expectEqual(@as(u32, 0), gate.ignored);
    try std.testing.expect(gate.quiet());
}

test "a store made with the PLL running is dropped and counted" {
    var gate = lock.Locked{};
    try std.testing.expect(!gate.takes(0));
    try std.testing.expect(!gate.takes(0));
    try std.testing.expectEqual(@as(u32, 2), gate.ignored);
    try std.testing.expect(!gate.quiet());
}

test "only PLLSTP decides, not the rest of DPHYPLOCR" {
    var gate = lock.Locked{};
    try std.testing.expect(gate.takes(0xFFFF_FFFF));
    try std.testing.expect(!gate.takes(0xFFFF_FFFE));
    try std.testing.expectEqual(@as(u32, 1), gate.ignored);
}
