//! Covers src/chip/periph/canfd/sleep.zig: the sleep request beside the mode
//! field, and the mode write it swallows.
const std = @import("std");
const ra8 = @import("ra8");
const sleep = ra8.chip.periph.canfd_sleep;
const canfd = ra8.chip.periph.canfd;

test "a machine comes out of reset asleep" {
    const machine = sleep.Request{};
    try std.testing.expect(machine.asleep);
    try std.testing.expectEqual(sleep.status, machine.statusBit());
}

test "a store that leaves the request set carries no mode" {
    var machine = sleep.Request{};
    try std.testing.expect(!machine.store(sleep.request | 2));
    try std.testing.expect(machine.asleep);
    try std.testing.expectEqual(@as(u32, 1), machine.ignored);
}

test "a store that clears the request carries its mode through" {
    var machine = sleep.Request{};
    try std.testing.expect(machine.store(2));
    try std.testing.expect(!machine.asleep);
    try std.testing.expectEqual(@as(u32, 0), machine.ignored);
    try std.testing.expectEqual(@as(u32, 0), machine.statusBit());
}

test "an awake machine can be put back to sleep" {
    var machine = sleep.Request{};
    _ = machine.store(0);
    try std.testing.expect(machine.store(sleep.request));
    try std.testing.expect(machine.asleep);
    try std.testing.expectEqual(@as(u32, 0), machine.ignored);
}

test "the pair counts both machines" {
    var pair = sleep.Pair{};
    _ = pair.global.store(sleep.request);
    _ = pair.channel.store(sleep.request);
    try std.testing.expect(!pair.quiet());
    try std.testing.expectEqual(@as(u32, 2), pair.ignored());
}

test "CFDCnSTS reports the sleep status beside the reset status" {
    var block = canfd.Canfd.init();
    const base = canfd.unitBase(0);
    const status = block.read(base + canfd.off_cnsts, 4);
    try std.testing.expectEqual(canfd.field.crststs | sleep.status, status);
}

test "a mode write with CSLPR still set moves the channel nowhere" {
    var block = canfd.Canfd.init();
    const base = canfd.unitBase(0);
    // CHMDC = operation, but the sleep request left standing.
    block.write(base + canfd.off_cnctr, 4, sleep.request);
    const status = block.read(base + canfd.off_cnsts, 4);
    try std.testing.expectEqual(canfd.field.crststs | sleep.status, status);
}

test "the driver's single store clears the request and lands the mode" {
    var block = canfd.Canfd.init();
    const base = canfd.unitBase(0);
    block.write(base + canfd.off_gctr, 4, 0);
    block.write(base + canfd.off_cnctr, 4, 0);
    try std.testing.expectEqual(@as(u32, 0), block.read(base + canfd.off_gsts, 4));
    try std.testing.expectEqual(@as(u32, 0), block.read(base + canfd.off_cnsts, 4));
}
