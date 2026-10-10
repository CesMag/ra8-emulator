//! Tests for src/chip/periph/sdramc.zig.
const std = @import("std");
const ra8 = @import("ra8");
const sdram = ra8.chip.periph.clocks.sdram;

fn reg(offset: u32) u32 {
    return sdram.base + offset;
}

test "an image that touched nothing here stays out of the report" {
    var unit: sdram.Sdramc = .{};
    try std.testing.expect(unit.quiet());
}

test "the byte controls read back what the driver wrote" {
    var unit: sdram.Sdramc = .{};
    unit.write(reg(sdram.off.sdcmod), 1, 0x01);
    unit.write(reg(sdram.off.sdamod), 1, 0x01);
    unit.write(reg(sdram.off.sdccr), 1, 0x11);
    try std.testing.expectEqual(@as(u32, 0x11), unit.read(reg(sdram.off.sdccr), 1));
    try std.testing.expectEqual(@as(u32, 0x01), unit.read(reg(sdram.off.sdcmod), 1));
    try std.testing.expectEqual(@as(u32, 0x01), unit.read(reg(sdram.off.sdamod), 1));
    try std.testing.expect(!unit.quiet());
}

test "halfword and word registers keep their neighbours apart" {
    var unit: sdram.Sdramc = .{};
    unit.write(reg(sdram.off.sdrfcr), 2, 0x1234);
    unit.write(reg(sdram.off.sdrfen), 1, 0x01);
    unit.write(reg(sdram.off.sdtr), 4, 0x0002_0102);
    unit.write(reg(sdram.off.sdmod), 2, 0x0230);
    try std.testing.expectEqual(@as(u32, 0x1234), unit.read(reg(sdram.off.sdrfcr), 2));
    try std.testing.expectEqual(@as(u32, 0x01), unit.read(reg(sdram.off.sdrfen), 1));
    try std.testing.expectEqual(@as(u32, 0x0002_0102), unit.read(reg(sdram.off.sdtr), 4));
    try std.testing.expectEqual(@as(u32, 0x0230), unit.read(reg(sdram.off.sdmod), 2));
}

test "SDSR reads clear after init, mode set and self-refresh start" {
    var unit: sdram.Sdramc = .{};
    unit.write(reg(sdram.off.sdir), 2, 0x0123);
    unit.write(reg(sdram.off.sdicr), 1, 0x01);
    try std.testing.expectEqual(@as(u32, 0), unit.read(reg(sdram.off.sdsr), 1));
    unit.write(reg(sdram.off.sdmod), 2, 0x0030);
    unit.write(reg(sdram.off.sdself), 1, 0x01);
    try std.testing.expectEqual(@as(u32, 0), unit.read(reg(sdram.off.sdsr), 1));
}

test "SDSR is read-only" {
    var unit: sdram.Sdramc = .{};
    unit.write(reg(sdram.off.sdsr), 1, 0x19);
    try std.testing.expectEqual(@as(u32, 0), unit.read(reg(sdram.off.sdsr), 1));
    try std.testing.expect(unit.quiet());
}

test "SDCKOCR holds its byte" {
    var unit: sdram.Sdramc = .{};
    unit.write(sdram.sdckocr_address, 1, 0x01);
    try std.testing.expectEqual(@as(u32, 0x01), unit.read(sdram.sdckocr_address, 1));
}

test "attach claims both windows on the bus" {
    var bus = ra8.chip.periph.registry.Bus.init(std.testing.allocator);
    defer bus.deinit();
    var unit: sdram.Sdramc = .{};
    try unit.attach(&bus);
    bus.write(reg(sdram.off.sdccr), 1, 0x11);
    bus.write(sdram.sdckocr_address, 1, 0x01);
    try std.testing.expectEqual(@as(u32, 0x11), unit.read(reg(sdram.off.sdccr), 1));
    try std.testing.expectEqual(@as(u32, 0x01), unit.sdckocr);
}
