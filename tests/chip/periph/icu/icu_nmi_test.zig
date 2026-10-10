//! Tests for src/chip/periph/icu/icu_nmi.zig.
const std = @import("std");
const ra8 = @import("ra8");
const nmi = ra8.chip.periph.icu.nmi;

fn reg(offset: u32) u32 {
    return nmi.base + offset;
}

test "the block sits where ra8_icu_init writes" {
    try std.testing.expectEqual(@as(u32, 0x4000_C100), reg(nmi.off.nmier));
    try std.testing.expectEqual(@as(u32, 0x4000_C110), reg(nmi.off.nmiclr));
    try std.testing.expectEqual(@as(u32, 0x4000_C1A0), reg(nmi.off.wupen0));
    try std.testing.expectEqual(@as(u32, 0x4000_C1A4), reg(nmi.off.wupen1));
}

test "NMIER bits can be set but a zero store does not clear them" {
    var unit: nmi.Nmi = .{};
    unit.write(reg(nmi.off.nmier), 4, 0x3);
    unit.write(reg(nmi.off.nmier), 4, 0);
    try std.testing.expectEqual(@as(u32, 0x3), unit.read(reg(nmi.off.nmier), 4));
    try std.testing.expect(!unit.quiet());
}

test "NMICLR clears the status bits it is given and reads 0" {
    var unit: nmi.Nmi = .{ .status = 0x6 };
    unit.write(reg(nmi.off.nmiclr), 4, 0x2);
    try std.testing.expectEqual(@as(u32, 0x4), unit.read(reg(nmi.off.nmisr), 4));
    try std.testing.expectEqual(@as(u32, 0), unit.read(reg(nmi.off.nmiclr), 4));
}

test "NMISR ignores stores" {
    var unit: nmi.Nmi = .{};
    unit.write(reg(nmi.off.nmisr), 4, 0xFFFF_FFFF);
    try std.testing.expectEqual(@as(u32, 0), unit.read(reg(nmi.off.nmisr), 4));
}

test "WUPEN0 and WUPEN1 hold what was written" {
    var unit: nmi.Nmi = .{};
    unit.write(reg(nmi.off.wupen0), 4, 0x8000_0001);
    unit.write(reg(nmi.off.wupen1), 4, 0x10);
    try std.testing.expectEqual(@as(u32, 0x8000_0001), unit.read(reg(nmi.off.wupen0), 4));
    try std.testing.expectEqual(@as(u32, 0x10), unit.read(reg(nmi.off.wupen1), 4));
}

test "the board ICU puts the block on the bus" {
    var bus = ra8.chip.periph.registry.Bus.init(std.testing.allocator);
    defer bus.deinit();
    var unit: nmi.Nmi = .{};
    try bus.add(unit.block());
    bus.write(0x4000_C1A4, 4, 0x5);
    try std.testing.expectEqual(@as(u32, 0x5), unit.wake[1]);
}
