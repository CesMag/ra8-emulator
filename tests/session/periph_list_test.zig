//! The session's peripheral layouts (RA8EMU-818): RTC's registers come from
//! rtc.off decl by decl in offset order, a model with no declared width
//! prints "?", every paired name is what its model's block reports, and the
//! block listing has one line per block on the bus.
const std = @import("std");
const ra8 = @import("ra8");
const chip = ra8.chip.periph;
const periph_list = ra8.session.periph_list;

test "RTC's registers are rtc.off in offset order" {
    const found = periph_list.registers("rtc") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 19), found.len);
    try std.testing.expectEqualStrings("r64cnt", found[0].name);
    try std.testing.expectEqualStrings("seccnt", found[1].name);
    try std.testing.expectEqual(chip.rtc.off.seccnt, found[1].offset);
    try std.testing.expectEqualStrings("rcr4", found[found.len - 1].name);
    try std.testing.expectEqual(chip.rtc.off.rcr4, found[found.len - 1].offset);
    var index: usize = 1;
    while (index < found.len) : (index += 1) try std.testing.expect(found[index - 1].offset < found[index].offset);
}

test "an unpaired block is unknown and an undeclared width prints ?" {
    try std.testing.expect(periph_list.registers("NOPE") == null);
    var out: [64]u8 = undefined;
    try std.testing.expectError(error.UnknownBlock, periph_list.writeRegisters("NOPE", &out));
    var big: [2048]u8 = undefined;
    const text = try periph_list.writeRegisters("RTC", &big);
    try std.testing.expect(std.mem.startsWith(u8, text, "r64cnt 0x00 ?\nseccnt 0x02 ?\n"));
}

test "each paired block lists the registers its model declares" {
    for (periph_list.layouts) |layout| {
        try std.testing.expect(layout.registers.len > 0);
        try std.testing.expect(periph_list.registers(layout.block) != null);
    }
}

test "the block listing has one line per block on the bus" {
    var bus = chip.registry.Bus.init(std.testing.allocator);
    defer bus.deinit();
    var rtc = chip.rtc.Rtc{};
    try bus.add(rtc.block());
    var out: [256]u8 = undefined;
    const text = try periph_list.writeBlocks(&bus, &out);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, text, "\n"));
    try std.testing.expect(std.mem.startsWith(u8, text, "RTC 0x"));
    try std.testing.expectEqual(@as(usize, 1), periph_list.blocks(&bus).len);
}
