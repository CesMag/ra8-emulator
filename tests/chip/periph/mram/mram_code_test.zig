//! Covers src/chip/periph/mram/mram_code.zig: the code-MRAM program-control page, the
//! status word it answers with, and the store to that word it refuses.
const std = @import("std");
const ra8 = @import("ra8");

const code = ra8.chip.periph.mram_code;
const mram = ra8.chip.periph.mram;

const page = code.page;
const mrcps = page.base + page.off_mrcps;
const gate = page.base;

test "MRCPS reads idle and ready" {
    var unit = code.Page{};
    try std.testing.expectEqual(page.ready, unit.read(mrcps, 4));
}

test "a store to MRCPS is refused and counted" {
    var unit = code.Page{};
    unit.write(mrcps, 4, 0xFFFF_FFFF);
    try std.testing.expectEqual(@as(u32, 1), unit.refused);
    try std.testing.expectEqual(page.ready, unit.read(mrcps, 4));
}

test "a byte store inside MRCPS is refused too" {
    var unit = code.Page{};
    unit.write(mrcps + 3, 1, 0xAA);
    unit.write(mrcps + 1, 2, 0xBEEF);
    try std.testing.expectEqual(@as(u32, 2), unit.refused);
    try std.testing.expectEqual(page.ready, unit.read(mrcps, 4));
}

test "a gate word keeps what firmware wrote" {
    var unit = code.Page{};
    unit.write(gate, 4, 0xA5A5_0001);
    try std.testing.expectEqual(@as(u32, 0xA5A5_0001), unit.read(gate, 4));
    try std.testing.expect(unit.quiet());
}

test "a narrow store to a gate word leaves the bytes it does not name" {
    var unit = code.Page{};
    unit.write(gate, 4, 0x1122_3344);
    unit.write(gate + 1, 1, 0xFF);
    try std.testing.expectEqual(@as(u32, 0x1122_FF44), unit.read(gate, 4));
}

test "a narrow read of a gate word answers only the bytes it names" {
    var unit = code.Page{};
    unit.write(gate, 4, 0x1122_3344);
    try std.testing.expectEqual(@as(u32, 0x22), unit.read(gate + 2, 1));
    try std.testing.expectEqual(@as(u32, 0x1122), unit.read(gate + 2, 2));
}

test "a narrow read of MRCPS answers the part of ready it names" {
    var unit = code.Page{};
    try std.testing.expectEqual(page.ready, unit.read(mrcps, 1));
    try std.testing.expectEqual(@as(u32, 0), unit.read(mrcps + 1, 1));
}

test "an access past the page answers zero and files nothing" {
    var unit = code.Page{};
    unit.write(page.base + page.span, 4, 0xDEAD_BEEF);
    try std.testing.expectEqual(@as(u32, 0), unit.read(page.base + page.span, 4));
    try std.testing.expect(unit.quiet());
}

test "a quiet page has refused nothing" {
    var unit = code.Page{};
    try std.testing.expect(unit.quiet());
    unit.write(mrcps, 4, 0);
    try std.testing.expect(!unit.quiet());
}

test "the block on the bus carries the page's own refusal" {
    var unit = mram.Mram.init(std.testing.allocator);
    defer unit.deinit();

    const block = unit.codeBlock();
    try std.testing.expectEqual(page.base, block.base);
    try std.testing.expect(unit.quiet());
    block.writeFn(block.context, mrcps, 4, 0x20);
    try std.testing.expectEqual(@as(u32, 1), unit.code.refused);
    try std.testing.expect(!unit.quiet());
    try std.testing.expectEqual(page.ready, block.readFn(block.context, mrcps, 4));
}
