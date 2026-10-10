//! Tests for src/chip/periph/gpt/pdg.zig.
const std = @import("std");
const ra8 = @import("ra8");
const pdg = ra8.chip.periph.gpt.pdg;

test "the PDG comes up idle and every register reads zero" {
    const unit = pdg.Pdg.init();
    try std.testing.expect(unit.quiet());
    try std.testing.expect(!unit.running());
    try std.testing.expectEqual(@as(u32, 0), unit.read(pdg.base, 4));
    try std.testing.expectEqual(@as(u32, 0), unit.read(pdg.base + 0x18, 2));
}

test "the driver's bring-up sequence ends with the DLL running" {
    var unit = pdg.Pdg.init();
    const frange: u16 = 1 << 8;
    unit.write(pdg.base, 2, pdg.mask.dlyrst | frange);
    unit.write(pdg.base + 2, 2, 0);
    unit.write(pdg.base, 2, pdg.mask.dlyrst | pdg.mask.dllen | frange);
    try std.testing.expect(!unit.running());
    unit.write(pdg.base, 2, pdg.mask.dllen | frange);
    try std.testing.expect(unit.running());
    try std.testing.expectEqual(@as(u2, 1), unit.frange());
    try std.testing.expectEqual(@as(u32, 1), unit.releases);
    unit.write(pdg.base + 2, 2, 0x1);
    try std.testing.expect(unit.applied(0));
    try std.testing.expect(!unit.applied(1));
}

test "control registers keep only their writable bits" {
    var unit = pdg.Pdg.init();
    unit.write(pdg.base, 2, 0xFFFF);
    try std.testing.expectEqual(@as(u32, 0x0303), unit.read(pdg.base, 2));
    unit.write(pdg.base + 2, 2, 0xFFFF);
    try std.testing.expectEqual(@as(u32, 0x0F0F), unit.read(pdg.base + 2, 2));
}

test "delay cells land by edge, channel and pin and drop bits 15:7" {
    var unit = pdg.Pdg.init();
    unit.write(pdg.base + 0x18, 2, 0x40);
    unit.write(pdg.base + 0x1E, 2, 0x1FF);
    unit.write(pdg.base + 0x2C, 2, 0x11);
    try std.testing.expectEqual(@as(u16, 0x40), unit.code(.rise, 0, .a));
    try std.testing.expectEqual(@as(u16, 0x7F), unit.code(.rise, 1, .b));
    try std.testing.expectEqual(@as(u16, 0x11), unit.code(.fall, 1, .a));
    try std.testing.expectEqual(@as(u32, 0x40), unit.read(pdg.base + 0x18, 2));
}

test "a 32-bit store covers both halfwords" {
    var unit = pdg.Pdg.init();
    unit.write(pdg.base + 0x28, 4, 0x0022_0011);
    try std.testing.expectEqual(@as(u16, 0x11), unit.code(.fall, 0, .a));
    try std.testing.expectEqual(@as(u16, 0x22), unit.code(.fall, 0, .b));
    try std.testing.expectEqual(@as(u32, 0x0022_0011), unit.read(pdg.base + 0x28, 4));
}

test "the gap between GTDLYCR2 and the first delay cell reads zero" {
    var unit = pdg.Pdg.init();
    unit.write(pdg.base + 0x8, 4, 0xFFFF_FFFF);
    try std.testing.expectEqual(@as(u32, 0), unit.read(pdg.base + 0x8, 4));
}

test "the block puts the PDG on the bus" {
    var bus = ra8.chip.periph.registry.Bus.init(std.testing.allocator);
    defer bus.deinit();
    var unit = pdg.Pdg.init();
    try bus.add(unit.block());
    bus.write(0x4032_4018, 2, 0x40);
    try std.testing.expectEqual(@as(u16, 0x40), unit.code(.rise, 0, .a));
}
