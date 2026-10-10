//! The PHY on the MDIO bus: what it answers, what it owns, and the frames it
//! refuses.
const std = @import("std");
const ra8 = @import("ra8");
const regs = ra8.chip.periph.eth_regs;
const eth_phy = ra8.components.eth_phy;

fn frame(target: u32, index: u32, op: regs.Op, data: u16) u32 {
    return regs.rmac.psme |
        (target << regs.rmac.pda_shift) |
        (index << regs.rmac.pra_shift) |
        (@as(u32, @backingInt(op)) << regs.rmac.pop_shift) |
        (@as(u32, data) << regs.rmac.prd_shift);
}

fn readBack(phy: *eth_phy.Phy, index: u32) u16 {
    return regs.dataOf(phy.transact(frame(eth_phy.address, index, .read, 0)));
}

test "the seeded PHY reports a negotiated link" {
    var phy = eth_phy.Phy.init();
    try std.testing.expectEqual(eth_phy.seed.bmsr, readBack(&phy, eth_phy.reg.bmsr));
    try std.testing.expectEqual(eth_phy.seed.anlpar, readBack(&phy, eth_phy.reg.anlpar));
}

test "a management read clears PSME" {
    var phy = eth_phy.Phy.init();
    const out = phy.transact(frame(eth_phy.address, eth_phy.reg.bmsr, .read, 0));
    try std.testing.expectEqual(@as(u32, 0), out & regs.rmac.psme);
}

test "a write to a register the PHY owns is refused" {
    var phy = eth_phy.Phy.init();
    _ = phy.transact(frame(eth_phy.address, eth_phy.reg.bmsr, .write, 0x0000));
    try std.testing.expectEqual(@as(u32, 1), phy.read_only);
    try std.testing.expectEqual(eth_phy.seed.bmsr, readBack(&phy, eth_phy.reg.bmsr));
}

test "a write to a control register is kept" {
    var phy = eth_phy.Phy.init();
    _ = phy.transact(frame(eth_phy.address, eth_phy.reg.anar, .write, 0x0061));
    try std.testing.expectEqual(@as(u16, 0x0061), readBack(&phy, eth_phy.reg.anar));
    try std.testing.expectEqual(@as(u32, 1), phy.writes);
}

test "a frame addressed to a PHY this board does not have reads an idle bus" {
    var phy = eth_phy.Phy.init();
    const out = phy.transact(frame(eth_phy.address + 3, eth_phy.reg.bmsr, .read, 0));
    try std.testing.expectEqual(eth_phy.idle_data, regs.dataOf(out));
    try std.testing.expectEqual(@as(u32, 1), phy.no_phy);
    try std.testing.expectEqual(@as(u32, 0), phy.reads);
}

test "a write meant for another PHY does not land here" {
    var phy = eth_phy.Phy.init();
    _ = phy.transact(frame(eth_phy.address + 1, eth_phy.reg.anar, .write, 0x1234));
    try std.testing.expectEqual(eth_phy.seed.anar, readBack(&phy, eth_phy.reg.anar));
}

test "a Clause-45 frame is refused rather than answered with stale data" {
    var phy = eth_phy.Phy.init();
    const out = phy.transact(frame(eth_phy.address, eth_phy.reg.bmsr, .read, 0) | regs.rmac.mff);
    try std.testing.expectEqual(@as(u16, 0), regs.dataOf(out));
    try std.testing.expectEqual(@as(u32, 1), phy.unsupported);
}

test "an operation that is not a Clause-22 read or write is refused" {
    var phy = eth_phy.Phy.init();
    _ = phy.transact(frame(eth_phy.address, eth_phy.reg.bmsr, .c45_address, 0));
    _ = phy.transact(frame(eth_phy.address, eth_phy.reg.bmsr, .c45_read, 0));
    try std.testing.expectEqual(@as(u32, 2), phy.bad_op);
}

test "BMCR.RESET is carried out and the file returns to power-on" {
    var phy = eth_phy.Phy.init();
    _ = phy.transact(frame(eth_phy.address, eth_phy.reg.anar, .write, 0x0061));
    _ = phy.transact(frame(eth_phy.address, eth_phy.reg.bmcr, .write, eth_phy.bmcr.reset));
    try std.testing.expectEqual(@as(u32, 1), phy.resets);
    try std.testing.expectEqual(eth_phy.seed.anar, readBack(&phy, eth_phy.reg.anar));
    try std.testing.expectEqual(eth_phy.seed.bmcr, readBack(&phy, eth_phy.reg.bmcr));
}

test "the auto-negotiation restart bit clears itself" {
    var phy = eth_phy.Phy.init();
    const asked = eth_phy.seed.bmcr | eth_phy.bmcr.restart_an;
    _ = phy.transact(frame(eth_phy.address, eth_phy.reg.bmcr, .write, asked));
    try std.testing.expectEqual(eth_phy.seed.bmcr, readBack(&phy, eth_phy.reg.bmcr));
}

test "a register past the Clause-22 space reads zero and stores nothing" {
    var phy = eth_phy.Phy.init();
    _ = phy.transact(frame(eth_phy.address, eth_phy.reg.count + 4, .write, 0xBEEF));
    try std.testing.expectEqual(@as(u16, 0), phy.value(eth_phy.reg.count + 4));
}

test "a PHY nothing touched is quiet, and a refusal alone is not" {
    var phy = eth_phy.Phy.init();
    try std.testing.expect(phy.quiet());
    _ = phy.transact(frame(eth_phy.address + 2, eth_phy.reg.bmsr, .read, 0));
    try std.testing.expect(!phy.quiet());
    try std.testing.expectEqual(@as(u32, 1), phy.refused());
}

test "the identity registers are read-only and unmodelled, so they read zero" {
    var phy = eth_phy.Phy.init();
    _ = phy.transact(frame(eth_phy.address, eth_phy.reg.id_high, .write, 0x0022));
    try std.testing.expectEqual(@as(u16, 0), readBack(&phy, eth_phy.reg.id_high));
    try std.testing.expectEqual(@as(u32, 1), phy.read_only);
}

test "as a port's MDIO bus it carries the frame to its own file" {
    var phy = eth_phy.Phy.init();
    const bus = phy.mdio();
    const out = bus.transact(frame(eth_phy.address, eth_phy.reg.bmsr, .read, 0));
    try std.testing.expectEqual(eth_phy.seed.bmsr, regs.dataOf(out));
    try std.testing.expectEqual(@as(u32, 1), phy.reads);
}
