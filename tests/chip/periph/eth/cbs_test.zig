//! CBS admin-to-operational register updates used by the TSN example.
const std = @import("std");
const ra8 = @import("ra8");
const Store = ra8.chip.core.cpu.memory.store.Store;
const eth = ra8.chip.periph.eth;
const regs = ra8.chip.periph.eth.regs;
const net = ra8.board.net;
const periph = ra8.chip.periph.registry;
const pdctr = ra8.chip.periph.pdctr;
const prcr = ra8.chip.periph.prcr;

const base = regs.cluster.etha0;

test "CBS configuration change copies admin values into operational monitors" {
    var unit = eth.cbs.Cbs.init(base);
    try std.testing.expectEqual(
        eth.cbs.off.upper_limit_mask,
        unit.read(base + eth.cbs.off.upper_limit, 4),
    );
    try std.testing.expectEqual(
        eth.cbs.off.upper_limit_mask,
        unit.read(base + eth.cbs.off.oper_upper_limit, 4),
    );
    const class: u32 = 2;
    const bit = @as(u32, 1) << class;
    const increment: u32 = 1500;
    const upper: u32 = 65_536;

    unit.write(base + eth.cbs.off.increment + 4 * class, 4, increment);
    unit.write(base + eth.cbs.off.upper_limit + 4 * class, 4, upper);
    unit.write(base + eth.cbs.off.admin_enable, 4, bit);
    unit.write(base + eth.cbs.off.config_change, 4, bit);

    try std.testing.expectEqual(bit, unit.read(base + eth.cbs.off.oper_enable, 4));
    try std.testing.expectEqual(
        increment,
        unit.read(base + eth.cbs.off.oper_increment + 4 * class, 4),
    );
    try std.testing.expectEqual(
        upper,
        unit.read(base + eth.cbs.off.oper_upper_limit + 4 * class, 4),
    );
    try std.testing.expectEqual(@as(u32, 0), unit.read(base + eth.cbs.off.config_change, 4));
    try std.testing.expectEqual(@as(u32, 0), unit.read(base + eth.cbs.off.gate_state, 4));
}

test "CBS register window is connected to the powered board bus" {
    var bus = periph.Bus.init(std.testing.allocator);
    defer bus.deinit();
    var cluster = net.Rswitch{};
    var store = try Store.init(null);
    defer store.deinit();
    var guard = prcr.Prcr.init();
    guard.write(prcr.win_base, 2, prcr.unlockWord(pdctr.guard));
    var domain = pdctr.Pdctr.init(&guard, .eswm);
    domain.write(pdctr.Domain.eswm.base(), 1, 0);
    try cluster.attach(&bus, .{ .store = &store }, &domain);

    const bit: u32 = 1 << 2;
    bus.write(base + eth.cbs.off.increment + 8, 4, 1500);
    bus.write(base + eth.cbs.off.upper_limit + 8, 4, 65_536);
    bus.write(base + eth.cbs.off.admin_enable, 4, bit);
    bus.write(base + eth.cbs.off.config_change, 4, bit);
    try std.testing.expectEqual(bit, bus.read(base + eth.cbs.off.oper_enable, 4));
    try std.testing.expectEqual(@as(u32, 1500), bus.read(base + eth.cbs.off.oper_increment + 8, 4));
    try std.testing.expectEqual(
        @as(u32, 65_536),
        bus.read(base + eth.cbs.off.oper_upper_limit + 8, 4),
    );
}
