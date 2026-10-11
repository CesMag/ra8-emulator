//! CPSCU SRAM attribution: SRAMSAR, SRAMSABAR0..3 and SRAMESAR.
const std = @import("std");
const ra8 = @import("ra8");

const sram = ra8.chip.periph.cpscu.sram;

test "reset leaves every word zero and the unit quiet" {
    var unit = sram.Unit{};
    try std.testing.expect(unit.quiet());
    try std.testing.expectEqual(@as(u32, 0), unit.read(sram.sar_address, 4));
    for (0..sram.bank_count) |bank| {
        try std.testing.expectEqual(@as(u32, 0), unit.read(sram.sabar_base + @as(u32, @intCast(bank)) * 4, 4));
    }
    try std.testing.expectEqual(@as(u32, 0), unit.read(sram.esar_address, 4));
}

test "each boundary reads back what its bank was given" {
    var unit = sram.Unit{};
    const bounds = [_]u32{ 0x0004_0000, 0x000A_0000, 0x0010_0000, 0x0018_0000 };
    for (bounds, 0..) |bound, bank| unit.write(sram.sabar_base + @as(u32, @intCast(bank)) * 4, 4, bound);
    for (bounds, 0..) |bound, bank| {
        try std.testing.expectEqual(bound, unit.sabar[bank]);
        try std.testing.expectEqual(bound, unit.read(sram.sabar_base + @as(u32, @intCast(bank)) * 4, 4));
    }
    try std.testing.expectEqual(@as(u32, 4), unit.writes);
    try std.testing.expect(!unit.quiet());
}

test "bits outside each word's mask are dropped" {
    var unit = sram.Unit{};
    unit.write(sram.sar_address, 4, 0xFFFF_FFFF);
    unit.write(sram.sabar_base, 4, 0xFFFF_FFFF);
    unit.write(sram.esar_address, 4, 0xFFFF_FFFF);
    try std.testing.expectEqual(sram.sar_mask, unit.read(sram.sar_address, 4));
    try std.testing.expectEqual(sram.sabar_mask, unit.read(sram.sabar_base, 4));
    try std.testing.expectEqual(sram.esar_mask, unit.read(sram.esar_address, 4));
}

test "a narrow store changes only the bytes it names" {
    var unit = sram.Unit{};
    unit.write(sram.sabar_base + 4, 4, 0x000A_0000);
    unit.write(sram.sabar_base + 5, 1, 0xE0);
    try std.testing.expectEqual(@as(u32, 0x000A_E000), unit.read(sram.sabar_base + 4, 4));
    try std.testing.expectEqual(@as(u32, 0x0A), unit.read(sram.sabar_base + 6, 1));
}

test "the three windows sit at their CPSCU offsets" {
    var unit = sram.Unit{};
    const blocks = unit.blocks();
    try std.testing.expectEqual(@as(u32, 0x4000_8010), blocks[0].base);
    try std.testing.expectEqual(@as(u32, 0x4000_8400), blocks[1].base);
    try std.testing.expectEqual(@as(u32, 0x10), blocks[1].size);
    try std.testing.expectEqual(@as(u32, 0x4000_8510), blocks[2].base);
    for (blocks) |block| try std.testing.expect(block.size >= 4);
}
