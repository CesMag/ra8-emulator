//! The embedded PHY's PLL: what it takes to lock, and what it refuses to
//! report before then.
const std = @import("std");
const ra8 = @import("ra8");
const regs = ra8.chip.periph.usbhs.regs;
const usbhs_pll = ra8.chip.periph.usbhs.pll;

const clocked = true;

/// The bring-up ra8_usb_phy.c walks, minus the clock, which is SYSCFG's.
fn brought() usbhs_pll.Pll {
    var pll = usbhs_pll.Pll{};
    pll.setPhyset(regs.physet.clksel_24, clocked);
    pll.setLpsts(regs.lpsts.suspendm, clocked);
    return pll;
}

test "the PHY comes up powered down with its PLL in reset" {
    var pll = usbhs_pll.Pll{};
    try std.testing.expect(pll.physet & regs.physet.dirpd != 0);
    try std.testing.expect(pll.physet & regs.physet.pllreset != 0);
    try std.testing.expectEqual(@as(u16, 0), pll.status(clocked));
    try std.testing.expectEqual(@as(u32, 1), pll.stalled);
}

test "a run that brings the PHY up gets the lock" {
    var pll = brought();
    try std.testing.expectEqual(regs.pllsta.plllock, pll.status(clocked));
    try std.testing.expectEqual(@as(u32, 1), pll.locks);
    try std.testing.expectEqual(@as(u32, 0), pll.stalled);
}

test "the lock does not wait on USBE, only on the module clock" {
    var pll = brought();
    try std.testing.expectEqual(@as(u16, 0), pll.status(false));
    pll.clockChanged(clocked);
    try std.testing.expectEqual(regs.pllsta.plllock, pll.status(clocked));
}

test "the analog block still powered down holds the lock off" {
    var pll = usbhs_pll.Pll{};
    pll.setPhyset(regs.physet.dirpd | regs.physet.clksel_24, clocked);
    pll.setLpsts(regs.lpsts.suspendm, clocked);
    try std.testing.expectEqual(@as(u16, 0), pll.status(clocked));
}

test "the PLL held in reset holds the lock off" {
    var pll = usbhs_pll.Pll{};
    pll.setPhyset(regs.physet.pllreset | regs.physet.clksel_24, clocked);
    pll.setLpsts(regs.lpsts.suspendm, clocked);
    try std.testing.expectEqual(@as(u16, 0), pll.status(clocked));
}

test "a PHY clock that never starts holds the lock off" {
    var pll = usbhs_pll.Pll{};
    pll.setPhyset(regs.physet.clksel_24, clocked);
    try std.testing.expectEqual(@as(u16, 0), pll.status(clocked));
    try std.testing.expectEqual(@as(u32, 0), pll.locks);
}

test "dropping SUSPENDM again drops the lock, and taking it back re-locks" {
    var pll = brought();
    pll.setLpsts(0, clocked);
    try std.testing.expectEqual(@as(u16, 0), pll.status(clocked));
    pll.setLpsts(regs.lpsts.suspendm, clocked);
    try std.testing.expectEqual(regs.pllsta.plllock, pll.status(clocked));
    try std.testing.expectEqual(@as(u32, 2), pll.locks);
}

test "an untouched PHY is quiet and a polled one is not" {
    var pll = usbhs_pll.Pll{};
    try std.testing.expect(pll.quiet());
    _ = pll.status(clocked);
    try std.testing.expect(!pll.quiet());
}
