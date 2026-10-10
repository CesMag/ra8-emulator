//! Covers src/chip/core/cpu/thumb_imm.zig.
const std = @import("std");
const ra8 = @import("ra8");
const thumb_imm = ra8.chip.core.cpu.thumb_imm;
const Instr = ra8.chip.core.cpu.instr.Instr;

fn expect(imm: u12, carry_in: bool, value: u32, carry: bool) !void {
    const got = thumb_imm.expandC(imm, carry_in) orelse return error.Unpredictable;
    try std.testing.expectEqual(value, got.result);
    try std.testing.expectEqual(carry, got.carry);
}

test "imm12 assembles i:imm3:imm8" {
    const instr: Instr = .{ .address = 0, .hw1 = 0xF44F, .hw2 = 0x4225, .size = 4 };
    try std.testing.expectEqual(@as(u12, 0xC25), thumb_imm.imm12(instr));
}

test "the four byte patterns keep the carry" {
    try expect(0x0AB, true, 0x0000_00AB, true);
    try expect(0x1AB, false, 0x00AB_00AB, false);
    try expect(0x2AB, true, 0xAB00_AB00, true);
    try expect(0x3AB, false, 0xABAB_ABAB, false);
}

test "a repeated zero byte is unpredictable" {
    try std.testing.expect(thumb_imm.expandC(0x100, false) == null);
    try std.testing.expect(thumb_imm.expandC(0x200, false) == null);
    try std.testing.expect(thumb_imm.expandC(0x300, false) == null);
    try expect(0x000, false, 0, false);
}

test "a rotated constant takes the carry from bit 31" {
    try expect(0xC25, true, 0x0000_A500, false);
    try expect(0x400, false, 0x8000_0000, true);
    try expect(0xF80, true, 0x0000_0100, false);
    try expect(0x4FF, false, 0x7F80_0000, false);
}
