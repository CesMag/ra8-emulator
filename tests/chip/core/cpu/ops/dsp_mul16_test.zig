//! Covers src/chip/core/cpu/ops/dsp_mul16.zig.
const std = @import("std");
const ra8 = @import("ra8");
const Cpu = ra8.chip.core.cpu.cpu.Cpu;
const dsp_mul16 = ra8.chip.core.cpu.ops.dsp_mul16;
const xpsr_bits = ra8.chip.core.cpu.regs.xpsr_bits;

fn wide(hw1: u16, hw2: u16) ra8.chip.core.cpu.instr.Instr {
    return .{ .address = 0, .hw1 = hw1, .hw2 = hw2, .size = 4 };
}

/// Runs the op with r1 = rn, r2 = rm, r3 = ra; returns r0 and Q.
fn run(hw1: u16, hw2: u16, rn: u32, rm: u32, ra: u32) !struct { u32, bool } {
    var cpu: Cpu = .{ .bus = undefined };
    cpu.regs.low[1] = rn;
    cpu.regs.low[2] = rm;
    cpu.regs.low[3] = ra;
    const exec = dsp_mul16.group.decode(wide(hw1, hw2)) orelse return error.NotClaimed;
    try exec(&cpu, wide(hw1, hw2));
    return .{ cpu.regs.low[0], cpu.regs.xpsr & xpsr_bits.q != 0 };
}

fn expectRun(hw1: u16, hw2: u16, rn: u32, rm: u32, ra: u32, value: u32, q: bool) !void {
    const got = try run(hw1, hw2, rn, rm, ra);
    try std.testing.expectEqual(value, got[0]);
    try std.testing.expectEqual(q, got[1]);
}

test "smulbb, smultb and smulbt pick signed halfwords" {
    try expectRun(0xFB11, 0xF002, 0x0005_FFFE, 0x0000_0003, 0, 0xFFFF_FFFA, false); // bb: -2*3
    try expectRun(0xFB11, 0xF022, 0x0005_FFFE, 0x0000_0003, 0, 15, false); // tb: 5*3
    try expectRun(0xFB11, 0xF012, 0x0000_0004, 0xFFFF_0000, 0, 0xFFFF_FFFC, false); // bt: 4*-1
}

test "smlabb adds Ra and sets Q on overflow" {
    try expectRun(0xFB11, 0x3002, 2, 3, 10, 16, false);
    try expectRun(0xFB11, 0x3002, 1, 1, 0x7FFF_FFFF, 0x8000_0000, true);
}

test "smulwb and smlawt keep bits 47:16" {
    try expectRun(0xFB31, 0xF002, 0x0001_0000, 0x0000_0003, 0, 3, false);
    try expectRun(0xFB31, 0x3012, 0x0002_0000, 0x0004_0000, 0x0000_0001, 0x0000_0009, false);
    try expectRun(0xFB31, 0x3002, 0x7FFF_FFFF, 0x0000_7FFF, 0x7FFF_FFFF, 0xBFFF_7FFE, true);
}

test "reserved bits, sp/pc and Ra = SP stay unclaimed" {
    try std.testing.expect(dsp_mul16.group.decode(wide(0xFB11, 0xF042)) == null); // hw2[6]
    try std.testing.expect(dsp_mul16.group.decode(wide(0xFB31, 0xF022)) == null); // hw2[5] on W
    try std.testing.expect(dsp_mul16.group.decode(wide(0xFB1D, 0xF002)) == null); // Rn = SP
    try std.testing.expect(dsp_mul16.group.decode(wide(0xFB11, 0xFF02)) == null); // Rd = PC
    try std.testing.expect(dsp_mul16.group.decode(wide(0xFB11, 0xD002)) == null); // Ra = SP
}
