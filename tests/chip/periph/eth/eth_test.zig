//! One R-Switch port on the bus: the mode registers a driver polls and the
//! MDIO window it brings the link up through.
const std = @import("std");
const ra8 = @import("ra8");
const Store = ra8.chip.core.cpu.memory.store.Store;
const periph = ra8.chip.periph.registry;
const regs = ra8.chip.periph.eth.regs;
const eth = ra8.chip.periph.eth;
const eth_phy = ra8.components.eth_phy;
const eth_mac = ra8.chip.periph.eth.mac;
const eth_mode = ra8.chip.periph.eth.mode;
const net = ra8.board.net;
const pdctr = ra8.chip.periph.pdctr;
const prcr = ra8.chip.periph.prcr;

fn portZero() eth.Port {
    return eth.Port.init(regs.cluster.etha0, regs.cluster.rmac0);
}

/// PRC1 unlocked, which is what a driver does before it touches PDCTRESWM.
fn unlockedGuard() prcr.Prcr {
    var guard = prcr.Prcr.init();
    guard.write(prcr.win_base, 2, prcr.unlockWord(pdctr.guard));
    return guard;
}

/// The ESWM domain already powered on, so a test about the windows is not a
/// test about the gate.
fn poweredEswm(guard: *const prcr.Prcr) pdctr.Pdctr {
    var domain = pdctr.Pdctr.init(guard, .eswm);
    domain.write(pdctr.Domain.eswm.base(), 1, 0);
    return domain;
}

fn mdio(index: u32, op: regs.Op, data: u16) u32 {
    return regs.rmac.psme |
        (eth_phy.address << regs.rmac.pda_shift) |
        (index << regs.rmac.pra_shift) |
        (@as(u32, @backingInt(op)) << regs.rmac.pop_shift) |
        (@as(u32, data) << regs.rmac.prd_shift);
}

test "EAMS reports the mode the port reached" {
    var port = portZero();
    for ([_]u32{ 1, 2 }) |code| port.ethaWrite(regs.cluster.etha0 + regs.etha.eamc, 4, code);
    try std.testing.expectEqual(@as(u32, 2), port.ethaRead(regs.cluster.etha0 + regs.etha.eams, 4));
}

test "EAMS is the port's to report, so a store there moves nothing" {
    var port = portZero();
    port.ethaWrite(regs.cluster.etha0 + regs.etha.eams, 4, 3);
    try std.testing.expectEqual(@as(u32, 1), port.ethaRead(regs.cluster.etha0 + regs.etha.eams, 4));
    try std.testing.expectEqual(@as(u32, 0), port.mode.commands);
}

test "a mode command from reset that skips a rung leaves status at reset" {
    var port = portZero();
    port.mode.mode = .reset;
    port.ethaWrite(regs.cluster.etha0 + regs.etha.eamc, 4, 3);
    try std.testing.expectEqual(@as(u32, 0), port.ethaRead(regs.cluster.etha0 + regs.etha.eams, 4));
    try std.testing.expectEqual(@as(u32, 1), port.mode.refused);
}

test "an MPSM read answers in the data field and clears PSME" {
    var phy = eth_phy.Phy.init();
    var port = portZero();
    port.mdio = phy.mdio();
    port.rmacWrite(regs.cluster.rmac0, 4, mdio(eth_phy.reg.bmsr, .read, 0));
    const out = port.rmacRead(regs.cluster.rmac0, 4);
    try std.testing.expectEqual(eth_phy.seed.bmsr, regs.dataOf(out));
    try std.testing.expectEqual(@as(u32, 0), out & regs.rmac.psme);
}

test "a port with nothing on its MDIO bus reads the idle level" {
    var port = portZero();
    port.rmacWrite(regs.cluster.rmac0, 4, mdio(eth_phy.reg.bmsr, .read, 0));
    const out = port.rmacRead(regs.cluster.rmac0, 4);
    try std.testing.expectEqual(eth_phy.idle_data, regs.dataOf(out));
    try std.testing.expectEqual(@as(u32, 0), out & regs.rmac.psme);
}

test "MPSM without PSME is a register, not a frame" {
    var phy = eth_phy.Phy.init();
    var port = portZero();
    port.mdio = phy.mdio();
    port.rmacWrite(regs.cluster.rmac0, 4, 0x1234_0000);
    try std.testing.expectEqual(@as(u32, 0x1234_0000), port.rmacRead(regs.cluster.rmac0, 4));
    try std.testing.expect(phy.quiet());
}

test "the two ports keep their own PHY" {
    var phy_one = eth_phy.Phy.init();
    var phy_two = eth_phy.Phy.init();
    var one = portZero();
    one.mdio = phy_one.mdio();
    var two = eth.Port.init(regs.cluster.etha1, regs.cluster.rmac1);
    two.mdio = phy_two.mdio();
    one.rmacWrite(regs.cluster.rmac0, 4, mdio(eth_phy.reg.anar, .write, 0x0041));
    two.rmacWrite(regs.cluster.rmac1, 4, mdio(eth_phy.reg.anar, .read, 0));
    try std.testing.expectEqual(eth_phy.seed.anar, regs.dataOf(two.rmacRead(regs.cluster.rmac1, 4)));
}

test "a frame built in two halfword stores goes out whole" {
    var phy = eth_phy.Phy.init();
    var port = portZero();
    port.mdio = phy.mdio();
    const at = regs.cluster.rmac0;
    const frame = mdio(eth_phy.reg.anar, .write, 0x0041);
    // Data half first, control half second: the order a driver that lays the
    // value down before arming the frame would use.
    port.rmacWrite(at + 2, 2, frame >> 16);
    port.rmacWrite(at, 2, frame & 0xFFFF);
    try std.testing.expectEqual(@as(u32, 1), phy.writes);
    try std.testing.expectEqual(@as(u16, 0x0041), phy.value(eth_phy.reg.anar));
}

test "the control half of MPSM leaves the data half alone" {
    var port = portZero();
    const at = regs.cluster.rmac0;
    port.rmacWrite(at + 2, 2, 0xBEEF);
    port.rmacWrite(at, 2, eth_phy.address << regs.rmac.pda_shift);
    try std.testing.expectEqual(@as(u16, 0xBEEF), regs.dataOf(port.rmacRead(at, 4)));
}

test "a halfword read of MPSM answers the half it names" {
    var phy = eth_phy.Phy.init();
    var port = portZero();
    port.mdio = phy.mdio();
    port.rmacWrite(regs.cluster.rmac0, 4, mdio(eth_phy.reg.bmsr, .read, 0));
    const high = port.rmacRead(regs.cluster.rmac0 + 2, 2);
    try std.testing.expectEqual(@as(u32, eth_phy.seed.bmsr), high);
}

test "a store above OPC is not a mode command" {
    var port = portZero();
    port.ethaWrite(regs.cluster.etha0 + regs.etha.eamc + 2, 2, 0xFFFF);
    try std.testing.expectEqual(@as(u32, 0), port.mode.commands);
}

test "a byte store at EAMC commands the port" {
    var port = portZero();
    port.ethaWrite(regs.cluster.etha0 + regs.etha.eamc, 1, 1);
    try std.testing.expectEqual(@as(u32, 1), port.ethaRead(regs.cluster.etha0 + regs.etha.eams, 1));
}

test "a port nothing touched is quiet" {
    const port = portZero();
    try std.testing.expect(port.quiet());
}

test "the cluster answers on the bus at every window it claims" {
    var bus = periph.Bus.init(std.testing.allocator);
    defer bus.deinit();
    var cluster = net.Rswitch{};
    var store = try Store.init(null);
    defer store.deinit();
    const guard = unlockedGuard();
    var domain = poweredEswm(&guard);
    try cluster.attach(&bus, .{ .store = &store }, &domain);
    bus.write(regs.cluster.etha0 + regs.etha.eamc, 4, 1);
    try std.testing.expectEqual(@as(u32, 1), bus.read(regs.cluster.etha0 + regs.etha.eams, 4));
    bus.write(regs.cluster.gwca0 + regs.gwca.gwmc, 4, 1);
    try std.testing.expectEqual(@as(u32, 1), bus.read(regs.cluster.gwca0 + regs.gwca.gwms, 4));
}

test "the cluster's config registers still read back off the bus" {
    var bus = periph.Bus.init(std.testing.allocator);
    defer bus.deinit();
    var cluster = net.Rswitch{};
    var store = try Store.init(null);
    defer store.deinit();
    const guard = unlockedGuard();
    var domain = poweredEswm(&guard);
    try cluster.attach(&bus, .{ .store = &store }, &domain);
    // An ETHA queue register nothing models: the bus remembers it, which is
    // all the C tree's flat shadow did for this address.
    bus.write(regs.cluster.etha0 + 0x0018, 4, 0xABCD);
    try std.testing.expectEqual(@as(u32, 0xABCD), bus.read(regs.cluster.etha0 + 0x0018, 4));
}

test "a cluster nothing touched is quiet" {
    const cluster = net.Rswitch{};
    try std.testing.expect(cluster.quiet());
}

test "a gated ESWM domain reads every port window back as zero" {
    const guard = prcr.Prcr.init();
    const domain = pdctr.Pdctr.init(&guard, .eswm);
    var port = portZero();
    port.domain = &domain;
    // Walking the mode machine up is exactly what a driver does first, and
    // none of it lands: EAMS answers DISABLE forever rather than CONFIG.
    port.ethaWrite(regs.cluster.etha0 + regs.etha.eamc, 4, 2);
    try std.testing.expectEqual(@as(u32, 0), port.ethaRead(regs.cluster.etha0 + regs.etha.eams, 4));
    try std.testing.expectEqual(@as(u32, 1), port.dropped_unpowered);
    try std.testing.expectEqual(@as(u32, 1), port.dark_reads);
}

test "a gated domain drops an MDIO frame instead of clocking it" {
    const guard = prcr.Prcr.init();
    const domain = pdctr.Pdctr.init(&guard, .eswm);
    var phy = eth_phy.Phy.init();
    var port = portZero();
    port.mdio = phy.mdio();
    port.domain = &domain;
    port.rmacWrite(regs.cluster.rmac0 + regs.rmac.mpsm, 4, mdio(1, .read, 0));
    try std.testing.expectEqual(@as(u32, 0), port.rmacRead(regs.cluster.rmac0 + regs.rmac.mpsm, 4));
    try std.testing.expect(phy.quiet());
    try std.testing.expectEqual(@as(u32, 1), port.dropped_unpowered);
}

test "a gated domain refuses the MAC address pair and reads it back as zero" {
    const guard = prcr.Prcr.init();
    const domain = pdctr.Pdctr.init(&guard, .eswm);
    var port = portZero();
    port.domain = &domain;
    port.ethaWrite(regs.cluster.etha0 + regs.etha.eamc, 4, 2);
    port.macWrite(regs.cluster.rmac0 + eth_mac.off.mrmac0, 4, 0x0211_2233);
    try std.testing.expectEqual(@as(u32, 0), port.macRead(regs.cluster.rmac0 + eth_mac.off.mrmac0, 4));
    try std.testing.expect(port.mac.quiet());
}

test "powering the domain on lets the same port answer again" {
    const guard = unlockedGuard();
    var domain = poweredEswm(&guard);
    var port = portZero();
    port.domain = &domain;
    // The mode machine still wants its rungs walked: the gate is the only
    // thing this test lifted.
    for ([_]u32{ 1, 2 }) |code| port.ethaWrite(regs.cluster.etha0 + regs.etha.eamc, 4, code);
    try std.testing.expectEqual(@as(u32, 2), port.ethaRead(regs.cluster.etha0 + regs.etha.eams, 4));
    try std.testing.expectEqual(@as(u32, 0), port.dropped_unpowered);
    try std.testing.expectEqual(@as(u32, 0), port.dark_reads);
}

test "gating the domain again after bring-up takes the windows back down" {
    const guard = unlockedGuard();
    var domain = poweredEswm(&guard);
    var port = portZero();
    port.domain = &domain;
    for ([_]u32{ 1, 2 }) |code| port.ethaWrite(regs.cluster.etha0 + regs.etha.eamc, 4, code);
    try std.testing.expectEqual(@as(u32, 2), port.ethaRead(regs.cluster.etha0 + regs.etha.eams, 4));
    domain.write(pdctr.Domain.eswm.base(), 1, pdctr.field.pdde);
    // The mode the machine reached is still held; the window just stopped
    // answering, which is the half a driver polling EAMS actually sees.
    try std.testing.expectEqual(@as(u32, 0), port.ethaRead(regs.cluster.etha0 + regs.etha.eams, 4));
    try std.testing.expectEqual(eth_mode.Mode.config, port.mode.mode);
}

test "a port with no domain attached is ungated" {
    var port = portZero();
    port.ethaWrite(regs.cluster.etha0 + regs.etha.eamc, 4, 1);
    try std.testing.expectEqual(@as(u32, 1), port.ethaRead(regs.cluster.etha0 + regs.etha.eams, 4));
    try std.testing.expectEqual(@as(u32, 0), port.dropped_unpowered);
    try std.testing.expectEqual(@as(u32, 0), port.dark_reads);
}

test "a dropped store leaves the port loud even though nothing else moved" {
    const guard = prcr.Prcr.init();
    const domain = pdctr.Pdctr.init(&guard, .eswm);
    var port = portZero();
    port.domain = &domain;
    try std.testing.expect(port.quiet());
    port.ethaWrite(regs.cluster.etha0 + regs.etha.eamc, 4, 2);
    try std.testing.expect(!port.quiet());
}
