//! Covers src/chip/core/cpu/ops/dsp_dual.zig.
const std = @import("std");
const ra8 = @import("ra8");
const Cpu = ra8.chip.core.cpu.cpu.Cpu;
const dsp_dual = ra8.chip.core.cpu.ops.dsp.dual;
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
    const exec = dsp_dual.group.decode(wide(hw1, hw2)) orelse return error.NotClaimed;
    try exec(&cpu, wide(hw1, hw2));
    return .{ cpu.regs.low[0], cpu.regs.xpsr & xpsr_bits.q != 0 };
}

fn expectRun(hw1: u16, hw2: u16, rn: u32, rm: u32, ra: u32, value: u32, q: bool) !void {
    const got = try run(hw1, hw2, rn, rm, ra);
    try std.testing.expectEqual(value, got[0]);
    try std.testing.expectEqual(q, got[1]);
}

test "smuad and smuadx add the two products" {
    // rn = (3, 2), rm = (5, 7): 2*7 + 3*5 = 29; swapped: 2*5 + 3*7 = 31
    try expectRun(0xFB21, 0xF002, 0x0003_0002, 0x0005_0007, 0, 29, false);
    try expectRun(0xFB21, 0xF012, 0x0003_0002, 0x0005_0007, 0, 31, false);
}

test "smuad sets Q when both products are 0x8000 squared" {
    try expectRun(0xFB21, 0xF002, 0x8000_8000, 0x8000_8000, 0, 0x8000_0000, true);
}

test "smlad adds Ra" {
    try expectRun(0xFB21, 0x3002, 0x0003_0002, 0x0005_0007, 100, 129, false);
    try expectRun(0xFB21, 0x3002, 0x0000_0001, 0x0000_0001, 0x7FFF_FFFF, 0x8000_0000, true);
}

test "smusd and smlsdx subtract the top product" {
    // 2*7 - 3*5 = -1
    try expectRun(0xFB41, 0xF002, 0x0003_0002, 0x0005_0007, 0, 0xFFFF_FFFF, false);
    // swapped: 2*5 - 3*7 = -11, plus 20
    try expectRun(0xFB41, 0x3012, 0x0003_0002, 0x0005_0007, 20, 9, false);
}

test "reserved bits, sp/pc and Ra = SP stay unclaimed" {
    try std.testing.expect(dsp_dual.group.decode(wide(0xFB21, 0xF022)) == null); // hw2[5]
    try std.testing.expect(dsp_dual.group.decode(wide(0xFB2D, 0xF002)) == null); // Rn = SP
    try std.testing.expect(dsp_dual.group.decode(wide(0xFB41, 0xFF02)) == null); // Rd = PC
    try std.testing.expect(dsp_dual.group.decode(wide(0xFB41, 0xD002)) == null); // Ra = SP
    try std.testing.expect(dsp_dual.group.decode(wide(0xFB31, 0xF002)) == null); // SMLAW row
}
