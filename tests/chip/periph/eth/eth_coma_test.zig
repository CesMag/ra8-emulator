//! Tests for src/chip/periph/eth/eth_coma.zig.
const std = @import("std");
const ra8 = @import("ra8");
const coma = ra8.chip.periph.eth.coma;

fn reg(unit: *const coma.Coma, offset: u32) u32 {
    return unit.base + offset;
}

test "a block nothing touched stays out of the report" {
    const unit: coma.Coma = .{};
    try std.testing.expect(unit.quiet());
    try std.testing.expectEqual(@as(u32, 0x403C_9000), unit.base);
}

test "the driver's RR pulse counts one reset and leaves RRC 0" {
    var unit: coma.Coma = .{};
    unit.write(reg(&unit, coma.off.rrc), 4, coma.bit.rr);
    unit.write(reg(&unit, coma.off.rrc), 4, 0);
    try std.testing.expectEqual(@as(u32, 1), unit.resets);
    try std.testing.expectEqual(@as(u32, 0), unit.read(reg(&unit, coma.off.rrc), 4));
    try std.testing.expect(!unit.quiet());
}

test "holding RR high is one reset, not one per store" {
    var unit: coma.Coma = .{};
    unit.write(reg(&unit, coma.off.rrc), 4, coma.bit.rr);
    unit.write(reg(&unit, coma.off.rrc), 4, coma.bit.rr);
    try std.testing.expectEqual(@as(u32, 1), unit.resets);
}

test "RCEC reads back and reports the switch clock" {
    var unit: coma.Coma = .{};
    try std.testing.expect(!unit.clockEnabled());
    unit.write(reg(&unit, coma.off.rcec), 4, coma.bit.rce | coma.bit.ace_mask);
    try std.testing.expect(unit.clockEnabled());
    try std.testing.expectEqual(@as(u32, 0x0001_007F), unit.read(reg(&unit, coma.off.rcec), 4));
}

test "RIC reads back what was written" {
    var unit: coma.Coma = .{};
    unit.write(reg(&unit, coma.off.ric), 4, 0x5);
    try std.testing.expectEqual(@as(u32, 0x5), unit.read(reg(&unit, coma.off.ric), 4));
}

test "the block puts RRC on the bus" {
    var bus = ra8.chip.periph.registry.Bus.init(std.testing.allocator);
    defer bus.deinit();
    var unit: coma.Coma = .{};
    try bus.add(unit.block());
    bus.write(0x403C_9004, 4, 1);
    try std.testing.expectEqual(@as(u32, 1), unit.resets);
}
