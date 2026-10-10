//! Covers src/chip/periph/ipc/repeat.zig: which IPC reads repeat unstepped.
const std = @import("std");
const ra8 = @import("ra8");
const ipc = ra8.chip.periph.ipc;
const sync = ra8.chip.periph.ipc_sync;

fn reg(channel: usize, offset: u32) u32 {
    return ipc.channelAddress(channel) + offset;
}

fn withBus(unit: *ipc.Ipc) !ra8.chip.periph.registry.Bus {
    var bus = ra8.chip.periph.registry.Bus.init(std.testing.allocator);
    errdefer bus.deinit();
    try bus.add(unit.block());
    return bus;
}

test "every channel's STA repeats at any width and changes nothing" {
    var unit = ipc.Ipc.init();
    var bus = try withBus(&unit);
    defer bus.deinit();
    bus.write(reg(0, ipc.off_txd), 4, 0x1234);
    const before = unit;
    for (0..ipc.ch_count) |index| {
        try std.testing.expect(bus.repeat(reg(index, ipc.off_sta), 4, 0));
        try std.testing.expect(bus.repeat(reg(index, ipc.off_sta), 4, 50));
        try std.testing.expect(bus.repeat(reg(index, ipc.off_sta) + 2, 1, 3));
    }
    try std.testing.expect(std.meta.eql(before.channels, unit.channels));
}

test "repeated STA reads are counted as reads" {
    var unit = ipc.Ipc.init();
    var bus = try withBus(&unit);
    defer bus.deinit();
    _ = bus.read(reg(2, ipc.off_sta), 4);
    const reads = bus.counters.reads;
    try std.testing.expect(bus.repeat(reg(2, ipc.off_sta), 4, 7));
    try std.testing.expectEqual(reads + 7, bus.counters.reads);
}

test "RXD, the actions and the window padding never repeat" {
    var unit = ipc.Ipc.init();
    var bus = try withBus(&unit);
    defer bus.deinit();
    const refused = [_]u32{ ipc.off_rxd, ipc.off_iset, ipc.off_txd, ipc.off_clr, 0x14, 0x1C };
    for (refused) |offset| {
        try std.testing.expect(!bus.repeat(reg(1, offset), 4, 4));
    }
}

test "the semaphore region still answers through the locks" {
    var unit = ipc.Ipc.init();
    var bus = try withBus(&unit);
    defer bus.deinit();
    const address = ipc.win_base + sync.semOffset(3);
    try std.testing.expect(!bus.repeat(address, 4, 2));
    _ = bus.read(address, 4);
    try std.testing.expect(bus.repeat(address, 4, 2));
    try std.testing.expectEqual(@as(u32, 2), unit.locks.semaphores[3].contentions);
}
