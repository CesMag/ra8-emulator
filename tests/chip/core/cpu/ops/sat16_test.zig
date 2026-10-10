//! Covers src/chip/core/cpu/ops/sat16.zig.
const std = @import("std");
const ra8 = @import("ra8");
const Cpu = ra8.chip.core.cpu.cpu.Cpu;
const sat16 = ra8.chip.core.cpu.ops.sat16;
const xpsr_bits = ra8.chip.core.cpu.regs.xpsr_bits;

fn wide(hw1: u16, hw2: u16) ra8.chip.core.cpu.instr.Instr {
    return .{ .address = 0, .hw1 = hw1, .hw2 = hw2, .size = 4 };
}

/// Runs r0 = op(r1) and returns r0 and whether Q is set.
fn run(hw1: u16, hw2: u16, rn: u32) !struct { u32, bool } {
    var cpu: Cpu = .{ .bus = undefined };
    cpu.regs.low[1] = rn;
    const exec = sat16.group.decode(wide(hw1, hw2)) orelse return error.NotClaimed;
    try exec(&cpu, wide(hw1, hw2));
    return .{ cpu.regs.low[0], cpu.regs.xpsr & xpsr_bits.q != 0 };
}

fn expectRun(hw1: u16, hw2: u16, rn: u32, value: u32, q: bool) !void {
    const got = try run(hw1, hw2, rn);
    try std.testing.expectEqual(value, got[0]);
    try std.testing.expectEqual(q, got[1]);
}

test "ssat16 r0, #8, r1 clamps each halfword to -128..127" {
    try expectRun(0xF321, 0x0007, 0x0012_FFF0, 0x0012_FFF0, false);
    try expectRun(0xF321, 0x0007, 0x0200_FE00, 0x007F_FF80, true);
}

test "usat16 r0, #8, r1 clamps each halfword to 0..255" {
    try expectRun(0xF3A1, 0x0008, 0x0012_00F0, 0x0012_00F0, false);
    try expectRun(0xF3A1, 0x0008, 0x0200_FFFF, 0x00FF_0000, true);
}

test "usat16 #0 leaves only zero" {
    try expectRun(0xF3A1, 0x0000, 0x0001_0000, 0x0000_0000, true);
}

test "shifted saturate rows and sp/pc stay unclaimed" {
    try std.testing.expect(sat16.group.decode(wide(0xF321, 0x1007)) == null); // imm3 set
    try std.testing.expect(sat16.group.decode(wide(0xF321, 0x0047)) == null); // imm2 set
    try std.testing.expect(sat16.group.decode(wide(0xF321, 0x0017)) == null); // hw2[4]
    try std.testing.expect(sat16.group.decode(wide(0xF32D, 0x0007)) == null); // Rn = SP
    try std.testing.expect(sat16.group.decode(wide(0xF321, 0x0F07)) == null); // Rd = PC
    try std.testing.expect(sat16.group.decode(wide(0xF301, 0x0007)) == null); // SSAT LSL
}
