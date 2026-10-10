//! Covers src/chip/core/cpu/ops/sat_arith.zig.
const std = @import("std");
const ra8 = @import("ra8");
const Cpu = ra8.chip.core.cpu.cpu.Cpu;
const sat_arith = ra8.chip.core.cpu.ops.sat_arith;
const xpsr_bits = ra8.chip.core.cpu.regs.xpsr_bits;

fn wide(hw1: u16, hw2: u16) ra8.chip.core.cpu.instr.Instr {
    return .{ .address = 0, .hw1 = hw1, .hw2 = hw2, .size = 4 };
}

/// Runs r0 = op(Rm = r2, Rn = r1) and returns r0 and whether Q is set.
fn run(hw2: u16, rm: u32, rn: u32) !struct { u32, bool } {
    var cpu: Cpu = .{ .bus = undefined };
    cpu.regs.low[1] = rn;
    cpu.regs.low[2] = rm;
    const exec = sat_arith.group.decode(wide(0xFA81, hw2)) orelse return error.NotClaimed;
    try exec(&cpu, wide(0xFA81, hw2));
    return .{ cpu.regs.low[0], cpu.regs.xpsr & xpsr_bits.q != 0 };
}

fn expectRun(hw2: u16, rm: u32, rn: u32, value: u32, q: bool) !void {
    const got = try run(hw2, rm, rn);
    try std.testing.expectEqual(value, got[0]);
    try std.testing.expectEqual(q, got[1]);
}

test "qadd in range and saturating both ways" {
    try expectRun(0xF082, 5, 7, 12, false);
    try expectRun(0xF082, 0x7FFF_FFFF, 1, 0x7FFF_FFFF, true);
    try expectRun(0xF082, 0x8000_0000, 0xFFFF_FFFF, 0x8000_0000, true);
}

test "qsub is Rm minus Rn" {
    try expectRun(0xF0A2, 10, 3, 7, false);
    try expectRun(0xF0A2, 0x8000_0000, 1, 0x8000_0000, true);
}

test "the doubling saturates and sets Q on its own" {
    try expectRun(0xF092, 1, 2, 5, false); // qdadd: 1 + 2*2
    try expectRun(0xF092, 0xFFFF_FFFF, 0x4000_0000, 0x7FFF_FFFE, true);
    try expectRun(0xF0B2, 0, 0xC000_0000, 0x7FFF_FFFF, true); // qdsub: 0 - sat(2*-2^30)
}

test "sp/pc and the parallel rows stay unclaimed" {
    try std.testing.expect(sat_arith.group.decode(wide(0xFA8D, 0xF082)) == null); // Rn = SP
    try std.testing.expect(sat_arith.group.decode(wide(0xFA81, 0xFF82)) == null); // Rd = PC
    try std.testing.expect(sat_arith.group.decode(wide(0xFA81, 0xF002)) == null); // SADD8
    try std.testing.expect(sat_arith.group.decode(wide(0xFA91, 0xF082)) == null); // REV.W row
}
