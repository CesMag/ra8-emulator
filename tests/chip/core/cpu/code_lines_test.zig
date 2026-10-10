//! Covers src/chip/core/cpu/code_lines.zig.
const std = @import("std");
const ra8 = @import("ra8");
const memmap = ra8.chip.core.memmap;
const code_lines = ra8.chip.core.cpu.decode.code_lines;

fn fresh() code_lines.CodeLines {
    var lines: code_lines.CodeLines = undefined;
    lines.clear();
    return lines;
}

test "a block's lines are marked and a store over one clears it and goes dirty" {
    var lines = fresh();
    lines.mark(memmap.sram_base + 0x30, memmap.sram_base + 0x48);
    try std.testing.expect(lines.marked(memmap.sram_base + 0x00));
    try std.testing.expect(lines.marked(memmap.sram_base + 0x40));
    try std.testing.expect(!lines.marked(memmap.sram_base + 0x80));
    lines.stored(memmap.sram_base + 0x44, 4);
    try std.testing.expect(lines.dirty);
    try std.testing.expect(!lines.marked(memmap.sram_base + 0x40));
    try std.testing.expect(lines.marked(memmap.sram_base + 0x00));
    try std.testing.expectEqual(code_lines.line(memmap.sram_base + 0x40).?, lines.low);
    try std.testing.expectEqual(lines.low, lines.high);
}

test "a store to an unmarked line or an untracked address leaves nothing dirty" {
    var lines = fresh();
    lines.mark(memmap.mram_base, memmap.mram_base + 8);
    lines.stored(memmap.mram_base + 0x100, 4);
    lines.stored(0x4000_0000, 4);
    try std.testing.expect(!lines.dirty);
    try std.testing.expect(code_lines.line(0x4000_0000) == null);
}

test "the Non-secure SRAM alias lands on the same line" {
    try std.testing.expectEqual(code_lines.line(memmap.sram_base + 0x1234).?, code_lines.line(memmap.ns_sram_base + 0x1234).?);
    var lines = fresh();
    lines.mark(memmap.sram_base + 0x200, memmap.sram_base + 0x210);
    lines.stored(memmap.ns_sram_base + 0x208, 2);
    try std.testing.expect(lines.dirty);
}

test "a store spanning two marked lines dirties both" {
    var lines = fresh();
    lines.mark(memmap.dtcm_base + 0x38, memmap.dtcm_base + 0x48);
    lines.stored(memmap.dtcm_base + 0x3E, 4);
    try std.testing.expectEqual(code_lines.line(memmap.dtcm_base).?, lines.low);
    try std.testing.expectEqual(code_lines.line(memmap.dtcm_base + 0x40).?, lines.high);
}

test "the Non-secure MRAM alias lands on the same line (RA8EMU-412)" {
    try std.testing.expectEqual(code_lines.line(memmap.mram_base + 0x8_0040).?, code_lines.line(memmap.ns_mram_base + 0x8_0040).?);
    var lines = fresh();
    lines.mark(memmap.mram_base + 0x8_0000, memmap.mram_base + 0x8_0010);
    lines.stored(memmap.ns_mram_base + 0x8_0004, 4);
    try std.testing.expect(lines.dirty);
}

test "covers holds only when every line of the range is tracked" {
    try std.testing.expect(code_lines.covers(memmap.sram_base + 0x10, memmap.sram_base + 0x90));
    try std.testing.expect(code_lines.covers(memmap.ns_mram_base, memmap.ns_mram_base + 4));
    try std.testing.expect(!code_lines.covers(0, 8));
    try std.testing.expect(!code_lines.covers(memmap.sram_end - 4, memmap.sram_end + 4));
    try std.testing.expect(!code_lines.covers(memmap.sram_base, memmap.sram_base));
}

test "the Non-secure MRAM alias lands on the same line" {
    try std.testing.expectEqual(code_lines.line(memmap.mram_base + 0x400).?, code_lines.line(memmap.ns_mram_base + 0x400).?);
}
