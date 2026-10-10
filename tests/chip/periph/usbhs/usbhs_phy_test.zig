//! The controller's power and port machine: what it takes to bring it up,
//! and what it refuses before then.
const std = @import("std");
const ra8 = @import("ra8");
const regs = ra8.chip.periph.usbhs_regs;
const usbhs_phy = ra8.chip.periph.usbhs_phy;

fn poweredHost() usbhs_phy.Phy {
    var phy = usbhs_phy.Phy{};
    phy.setSyscfg(regs.syscfg.usbe | regs.syscfg.scke | regs.syscfg.dcfm);
    return phy;
}

/// The bring-up the driver actually performs: powered, host role, receiver
/// on, and the jack's VBUS switch closed.
fn seeingHost() usbhs_phy.Phy {
    var phy = usbhs_phy.Phy{};
    phy.setSyscfg(regs.syscfg.usbe | regs.syscfg.scke | regs.syscfg.dcfm |
        regs.syscfg.cnen);
    _ = phy.setPort(regs.port.vbusen);
    return phy;
}

test "HS has no SCKE: the module clock is there from reset and USBE powers it" {
    var phy = usbhs_phy.Phy{};
    try std.testing.expect(phy.clocked());
    try std.testing.expect(!phy.powered());
    phy.setSyscfg(regs.syscfg.usbe);
    try std.testing.expect(phy.powered());
}

test "a store to bit 10 of the HS SYSCFG is dropped" {
    var phy = usbhs_phy.Phy{};
    phy.setSyscfg(regs.syscfg.scke);
    try std.testing.expectEqual(@as(u16, 0), phy.syscfg);
    try std.testing.expect(!phy.powered());
    phy.setSyscfg(regs.syscfg.usbe | regs.syscfg.scke | regs.syscfg.dcfm);
    try std.testing.expectEqual(regs.syscfg.usbe | regs.syscfg.dcfm, phy.syscfg);
}

test "the line reads idle until something is attached" {
    var phy = seeingHost();
    try std.testing.expectEqual(@as(u16, 0), phy.lineState());
    phy.attached = true;
    try std.testing.expectEqual(regs.port.lnst_j, phy.lineState());
}

test "an unpowered controller reports no line state at all" {
    var phy = usbhs_phy.Phy{};
    phy.attached = true;
    try std.testing.expectEqual(@as(u16, 0), phy.lineState());
}

test "a port write needs a powered controller" {
    var phy = usbhs_phy.Phy{};
    try std.testing.expect(!phy.setPort(regs.port.usbrst));
    try std.testing.expectEqual(@as(u32, 1), phy.off);
}

test "a port write needs the host role" {
    var phy = usbhs_phy.Phy{};
    phy.setSyscfg(regs.syscfg.usbe | regs.syscfg.scke);
    try std.testing.expect(!phy.setPort(regs.port.usbrst));
    try std.testing.expectEqual(@as(u32, 1), phy.not_host);
}

test "the speed is what the reset settled on, not what was asked for" {
    var phy = seeingHost();
    phy.attached = true;
    try std.testing.expectEqual(@as(u16, 0), phy.portStatus() & regs.port.rhst_mask);
    try std.testing.expect(phy.setPort(regs.port.vbusen | regs.port.usbrst));
    try std.testing.expectEqual(@as(u16, 0), phy.portStatus() & regs.port.rhst_mask);
    try std.testing.expect(phy.setPort(regs.port.vbusen));
    try std.testing.expectEqual(regs.port.rhst_high, phy.portStatus() & regs.port.rhst_mask);
    try std.testing.expectEqual(@as(u32, 1), phy.resets);
}

test "a reset with nothing attached settles on no speed" {
    var phy = poweredHost();
    _ = phy.setPort(regs.port.usbrst);
    _ = phy.setPort(0);
    try std.testing.expectEqual(@as(u32, 1), phy.resets);
    try std.testing.expectEqual(usbhs_phy.Speed.none, phy.speed);
}

test "holding USBRST does not count a reset" {
    var phy = poweredHost();
    phy.attached = true;
    _ = phy.setPort(regs.port.usbrst);
    _ = phy.setPort(regs.port.usbrst | regs.port.uact);
    try std.testing.expectEqual(@as(u32, 0), phy.resets);
}

test "turning the module off forgets the speed the port found" {
    var phy = seeingHost();
    phy.attached = true;
    _ = phy.setPort(regs.port.vbusen | regs.port.usbrst);
    _ = phy.setPort(regs.port.vbusen | regs.port.uact);
    try std.testing.expectEqual(usbhs_phy.Speed.high, phy.speed);
    phy.setSyscfg(0);
    try std.testing.expectEqual(usbhs_phy.Speed.none, phy.speed);
    try std.testing.expectEqual(@as(u16, 0), phy.portStatus() & regs.port.uact);
}

test "a brought-up controller that did nothing is not quiet once it refused" {
    var phy = poweredHost();
    try std.testing.expect(phy.quiet());
    phy.refuseStatus();
    try std.testing.expect(!phy.quiet());
    try std.testing.expectEqual(@as(u32, 1), phy.refusals());
}

test "the speed field reports the encoding the driver reads" {
    try std.testing.expectEqual(@as(u16, 0), usbhs_phy.Speed.none.rhst());
    try std.testing.expectEqual(regs.port.rhst_full, usbhs_phy.Speed.full.rhst());
    try std.testing.expectEqual(regs.port.rhst_high, usbhs_phy.Speed.high.rhst());
}

test "the receiver has to be on before the line says anything" {
    var phy = seeingHost();
    phy.attached = true;
    try std.testing.expectEqual(regs.port.lnst_j, phy.lineState());
    phy.setSyscfg(regs.syscfg.usbe | regs.syscfg.scke | regs.syscfg.dcfm);
    try std.testing.expect(!phy.receiving());
    try std.testing.expectEqual(@as(u16, 0), phy.lineState());
    try std.testing.expectEqual(@as(u32, 1), phy.blind);
}

test "an unpowered jack reads SE0 whatever is plugged into it" {
    var phy = seeingHost();
    phy.attached = true;
    _ = phy.setPort(0);
    try std.testing.expect(!phy.supplying());
    try std.testing.expectEqual(@as(u16, 0), phy.lineState());
    try std.testing.expectEqual(@as(u32, 1), phy.blind);
}

test "a blind read is only counted when there was something there to miss" {
    var phy = poweredHost();
    try std.testing.expectEqual(@as(u16, 0), phy.lineState());
    try std.testing.expectEqual(@as(u32, 0), phy.blind);
    var off = usbhs_phy.Phy{};
    off.attached = true;
    try std.testing.expectEqual(@as(u16, 0), off.lineState());
    try std.testing.expectEqual(@as(u32, 0), off.blind);
}

test "a reset the port could not observe settles on no speed" {
    var phy = poweredHost();
    phy.attached = true;
    _ = phy.setPort(regs.port.usbrst);
    _ = phy.setPort(0);
    try std.testing.expectEqual(@as(u32, 1), phy.resets);
    try std.testing.expectEqual(usbhs_phy.Speed.none, phy.speed);
    try std.testing.expectEqual(@as(u16, 0), phy.portStatus() & regs.port.rhst_mask);
}

test "a blind read alone keeps the controller off the quiet list" {
    var phy = seeingHost();
    phy.attached = true;
    phy.setSyscfg(regs.syscfg.usbe | regs.syscfg.scke | regs.syscfg.dcfm);
    _ = phy.lineState();
    try std.testing.expectEqual(@as(u32, 0), phy.refusals());
    try std.testing.expect(!phy.quiet());
}

test "both gates together are what the host bring-up writes" {
    var phy = usbhs_phy.Phy{};
    phy.setSyscfg(regs.syscfg.usbe | regs.syscfg.scke | regs.syscfg.dcfm |
        regs.syscfg.cnen);
    try std.testing.expect(phy.receiving());
    try std.testing.expect(!phy.sees());
    _ = phy.setPort(regs.port.vbusen);
    try std.testing.expect(phy.supplying());
    try std.testing.expect(phy.sees());
}

test "a device role wants its own pull-up, not the jack's switch" {
    var phy = usbhs_phy.Phy{};
    phy.setSyscfg(regs.syscfg.usbe | regs.syscfg.scke | regs.syscfg.cnen);
    phy.attached = true;
    try std.testing.expect(!phy.host());
    try std.testing.expect(!phy.pullingUp());
    try std.testing.expectEqual(@as(u16, 0), phy.lineState());
    try std.testing.expectEqual(@as(u32, 1), phy.blind);

    // VBUSEN is the host's bit and buys a device nothing.
    _ = phy.setPort(regs.port.vbusen);
    try std.testing.expectEqual(@as(u16, 0), phy.lineState());
    try std.testing.expectEqual(@as(u32, 2), phy.blind);

    phy.setSyscfg(regs.syscfg.usbe | regs.syscfg.scke | regs.syscfg.cnen |
        regs.syscfg.dprpu);
    try std.testing.expectEqual(regs.port.lnst_j, phy.lineState());
    try std.testing.expectEqual(@as(u32, 2), phy.blind);
}

test "the receiver is the one gate both roles share" {
    var phy = usbhs_phy.Phy{};
    phy.setSyscfg(regs.syscfg.usbe | regs.syscfg.scke | regs.syscfg.dprpu);
    phy.attached = true;
    try std.testing.expect(phy.pullingUp());
    try std.testing.expect(!phy.receiving());
    try std.testing.expectEqual(@as(u16, 0), phy.lineState());
    try std.testing.expectEqual(@as(u32, 1), phy.blind);
}

test "the attach order is CNEN before DPRPU, and the line waits for both" {
    var phy = usbhs_phy.Phy{};
    phy.setSyscfg(regs.syscfg.usbe | regs.syscfg.scke);
    phy.attached = true;
    try std.testing.expect(!phy.sees());
    phy.setSyscfg(regs.syscfg.usbe | regs.syscfg.scke | regs.syscfg.cnen);
    try std.testing.expect(!phy.sees());
    phy.setSyscfg(regs.syscfg.usbe | regs.syscfg.scke | regs.syscfg.cnen |
        regs.syscfg.dprpu);
    try std.testing.expect(phy.sees());
    try std.testing.expectEqual(regs.port.lnst_j, phy.lineState());
}

test "a detach drops the pull-up and the line goes dark again" {
    var phy = usbhs_phy.Phy{};
    phy.setSyscfg(regs.syscfg.usbe | regs.syscfg.scke | regs.syscfg.cnen |
        regs.syscfg.dprpu);
    phy.attached = true;
    try std.testing.expectEqual(regs.port.lnst_j, phy.lineState());
    phy.setSyscfg(regs.syscfg.usbe | regs.syscfg.scke);
    try std.testing.expectEqual(@as(u16, 0), phy.lineState());
    try std.testing.expectEqual(@as(u32, 1), phy.blind);
}

test "DPRPU buys a host nothing, the way VBUSEN buys a device nothing" {
    var phy = usbhs_phy.Phy{};
    phy.setSyscfg(regs.syscfg.usbe | regs.syscfg.scke | regs.syscfg.dcfm |
        regs.syscfg.cnen | regs.syscfg.dprpu);
    phy.attached = true;
    try std.testing.expect(phy.host());
    try std.testing.expectEqual(@as(u16, 0), phy.lineState());
    _ = phy.setPort(regs.port.vbusen);
    try std.testing.expectEqual(regs.port.lnst_j, phy.lineState());
}

test "K-state is named with the encoding the manual gives" {
    try std.testing.expectEqual(@as(u16, 0b01), regs.port.lnst_j);
    try std.testing.expectEqual(@as(u16, 0b10), regs.port.lnst_k);
    try std.testing.expectEqual(@as(u16, 0b11), regs.port.lnst_mask);
}
