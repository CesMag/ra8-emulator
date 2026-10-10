//! Tests for src/chip/periph/lpm/lpm_dps.zig.
const std = @import("std");
const ra8 = @import("ra8");
const dps = ra8.chip.periph.lpm.dps;

test "the registers sit where ra8_lpm_regs.h puts them" {
    try std.testing.expectEqual(@as(u32, 0x4001_EA08), dps.addressOf(.enable, 0));
    try std.testing.expectEqual(@as(u32, 0x4001_EA10), dps.addressOf(.enable, 2));
    try std.testing.expectEqual(@as(u32, 0x4001_EA20), dps.addressOf(.flag, 2));
    try std.testing.expectEqual(@as(u32, 0x4001_EA30), dps.addressOf(.edge, 2));
    try std.testing.expectEqual(@as(u32, 0x4001_EA34), dps.base + dps.span);
}

test "an untouched block stays out of the report" {
    const unit: dps.Dps = .{};
    try std.testing.expect(unit.quiet());
}

test "enables and edges hold what was written" {
    var unit: dps.Dps = .{};
    unit.write(dps.addressOf(.enable, 2), 1, 0x5A);
    unit.write(dps.addressOf(.edge, 1), 1, 0x03);
    try std.testing.expectEqual(@as(u32, 0x5A), unit.read(dps.addressOf(.enable, 2), 1));
    try std.testing.expectEqual(@as(u32, 0x03), unit.read(dps.addressOf(.edge, 1), 1));
    try std.testing.expect(!unit.quiet());
}

test "a flag is cleared by 0 and never set by 1" {
    var unit: dps.Dps = .{};
    unit.write(dps.addressOf(.flag, 2), 1, 0xFF);
    try std.testing.expectEqual(@as(u32, 0), unit.read(dps.addressOf(.flag, 2), 1));
    unit.bytes[dps.enable_count + 2] = 0x0F;
    unit.write(dps.addressOf(.flag, 2), 1, 0xFA);
    try std.testing.expectEqual(@as(u32, 0x0A), unit.read(dps.addressOf(.flag, 2), 1));
}

test "the gaps between registers answer nothing" {
    var unit: dps.Dps = .{};
    unit.write(dps.addressOf(.enable, 0) + 1, 1, 0xFF);
    try std.testing.expect(unit.quiet());
    try std.testing.expect(dps.slotOf(dps.base + dps.span) == null);
}

test "the block puts every register on the bus" {
    var bus = ra8.chip.periph.registry.Bus.init(std.testing.allocator);
    defer bus.deinit();
    var unit: dps.Dps = .{};
    try bus.add(unit.block());
    bus.write(0x4001_EA10, 1, 0x11);
    try std.testing.expectEqual(@as(u8, 0x11), unit.bytes[2]);
}
