//! Tests for src/chip/periph/mrms/ecc.zig.
const std = @import("std");
const ra8 = @import("ra8");
const ecc = ra8.chip.periph.mrms.ecc;

const at = struct {
    fn reg(offset: u32) u32 {
        return ecc.base + offset;
    }
};

test "an image that touched nothing here stays out of the report" {
    var unit: ecc.Ecc = .{};
    try std.testing.expect(unit.quiet());
}

test "the keyed controls keep only their enable bit and never the key" {
    var unit: ecc.Ecc = .{};
    unit.write(at.reg(ecc.off.mrcdecc), 2, 0x8C00 | ecc.field.dececen);
    unit.write(at.reg(ecc.off.mrceecc), 2, 0xC000 | ecc.field.eccen);
    try std.testing.expectEqual(ecc.field.dececen, unit.read(at.reg(ecc.off.mrcdecc), 2));
    try std.testing.expectEqual(ecc.field.eccen, unit.read(at.reg(ecc.off.mrceecc), 2));
    try std.testing.expect(!unit.quiet());
}

test "a store without the key is dropped and counted" {
    var unit: ecc.Ecc = .{};
    unit.write(at.reg(ecc.off.mrcdecc), 2, 0xC000 | ecc.field.dececen);
    unit.write(at.reg(ecc.off.mrceecc), 2, ecc.field.eccen);
    try std.testing.expectEqual(@as(u32, 0), unit.read(at.reg(ecc.off.mrcdecc), 2));
    try std.testing.expectEqual(@as(u32, 0), unit.read(at.reg(ecc.off.mrceecc), 2));
    try std.testing.expectEqual(@as(u32, 1), unit.decoder.refused);
    try std.testing.expectEqual(@as(u32, 1), unit.encoder.refused);
}

test "error status only clears, and no error address is ever latched" {
    var unit: ecc.Ecc = .{ .code_status = ecc.field.pair, .extra_status = ecc.field.pair };
    unit.write(at.reg(ecc.off.mrcraes), 1, 0);
    unit.write(at.reg(ecc.off.mreraes), 1, 0xFF);
    try std.testing.expectEqual(@as(u32, 0), unit.read(at.reg(ecc.off.mrcraes), 1));
    try std.testing.expectEqual(ecc.field.pair, unit.read(at.reg(ecc.off.mreraes), 1));
    for ([_]u32{ ecc.off.mrcrtea, ecc.off.mrcrdea, ecc.off.mrertea, ecc.off.mrerdea }) |offset| {
        unit.write(at.reg(offset), 4, 0xDEAD_BEEF);
        try std.testing.expectEqual(@as(u32, 0), unit.read(at.reg(offset), 4));
    }
}

test "the irq enables and MRPSC hold their own bits" {
    var unit: ecc.Ecc = .{};
    unit.write(at.reg(ecc.off.mrcraeint), 1, 0xFF);
    unit.write(at.reg(ecc.off.mreraint), 1, 0x01);
    unit.write(at.reg(ecc.off.mrpsc), 1, 0xFF);
    try std.testing.expectEqual(ecc.field.pair, unit.read(at.reg(ecc.off.mrcraeint), 1));
    try std.testing.expectEqual(@as(u32, 1), unit.read(at.reg(ecc.off.mreraint), 1));
    try std.testing.expectEqual(ecc.field.mhspen, unit.read(at.reg(ecc.off.mrpsc), 1));
}

test "attach claims the three windows the driver writes" {
    var bus = ra8.chip.periph.registry.Bus.init(std.testing.allocator);
    defer bus.deinit();
    var unit: ecc.Ecc = .{};
    try unit.attach(&bus);
    try std.testing.expectEqual(@as(usize, 3), bus.count);
}
