//! Covers the Armv8.0-M system printers against their parity digests: src/chip/core/cpu/text/
//! sg.zig, tt.zig, udf.zig, bkpt.zig and bxns.zig.
const std = @import("std");
const ra8 = @import("ra8");
const parity = @import("parity.zig");
const Instr = ra8.chip.core.cpu.instr.Instr;
const disasm = ra8.chip.core.cpu.decode.text.disasm;

test "SG matches its parity digest" {
    try parity.expectWideGroupMatches("sg", 0xFFFF, 0xE97F, &.{ 0xE97F, 0xE97E });
}

/// Each T/A pairing with Rd r0, r2, r12, SP and PC, plus nonzero low bits.
const tt_hw2 = [_]u16{ 0xF000, 0xF040, 0xF080, 0xF0C0, 0xF200, 0xFC40, 0xFD80, 0xFFC0, 0xF001, 0xF03F };

test "TT, TTT, TTA and TTAT match their parity digests" {
    try parity.expectWideGroupMatches("tt", 0xFFF0, 0xE840, &tt_hw2);
}

/// UDF #0xf9: the reference disassembler could not decode it, so it is
/// checked by name below.
const reference_gap: u16 = 0xDEF9;

test "every other 16-bit udf encoding matches its parity digest" {
    try parity.expectGroupMatchesExcept("udf", &.{reference_gap});
}

test "UDF #0xf9, which the reference disassembler could not decode, prints its Arm name" {
    const instr: Instr = .{ .address = parity.address, .hw1 = reference_gap, .size = 2 };
    const ours = disasm.one(instr) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("udf #0xf9", ours.slice());
}

test "UDF.W matches its parity digest" {
    try parity.expectWideGroupMatches("udf", 0xFFF0, 0xF7F0, &.{ 0xA000, 0xA009, 0xA00A, 0xA234, 0xAFFF, 0xB000 });
}

test "every 16-bit bkpt encoding matches its parity digest" {
    try parity.expectGroupMatches("bkpt");
}

test "every 16-bit bxns encoding matches its parity digest" {
    try parity.expectGroupMatches("bxns");
}
