//! Covers src/chip/core/cpu/conformance/base/mve/reduce_vectors.zig: each vector
//! runs through the `mve_reduce` group with Q1, Q2, Rda, RdaHi, VPR, the IT
//! byte, LR and FPSCR.LTPSIZE set first.
const std = @import("std");
const ra8 = @import("ra8");
const vector = ra8.chip.core.cpu.conformance.vector;
const vectors = ra8.chip.core.cpu.conformance.base.mve.reduce_vectors;
const cpu_ns = ra8.chip.core.cpu;
const Cpu = cpu_ns.cpu.Cpu;
const it_state = cpu_ns.it_state;
const qreg = ra8.chip.core.cpu.mve.qreg;

/// RdaHi for the pair forms, or null for the single-register ones.
fn hiOf(hw1: u16) ?u4 {
    if (hw1 & 0x80 == 0 or hw1 & 0xF0 == 0xF0) return null;
    const hi: u4 = @intCast((hw1 >> 4 & 7) * 2 + 1);
    return if (hi == 13) null else hi;
}

fn run(in: vectors.In) vectors.Out {
    var cpu: Cpu = .{ .bus = undefined };
    qreg.write(&cpu.fp.bank, 1, in.qm);
    qreg.write(&cpu.fp.bank, 2, in.qn);
    cpu.fp.vpr = @bitCast(in.vpr);
    cpu.fp.fpscr.ltpsize = in.ltpsize;
    cpu.regs.xpsr = it_state.put(cpu.regs.xpsr, in.it);
    cpu.regs.set(14, in.lr);
    const rda: u4 = @intCast((in.hw2 >> 13) * 2);
    cpu.regs.set(rda, in.rda);
    const hi = hiOf(in.hw1);
    if (hi) |r| cpu.regs.set(r, in.rda_hi);
    const instr: cpu_ns.instr.Instr = .{ .address = 0x100, .hw1 = in.hw1, .hw2 = in.hw2, .size = @intCast(in.size) };
    const exec = cpu_ns.ops.mve.reduce.group.decode(instr) orelse return vectors.none;
    exec(&cpu, instr) catch unreachable;
    const out_hi = if (hi) |r| cpu.regs.get(r) else 0;
    return .{ .rda = cpu.regs.get(rda), .rda_hi = out_hi, .vpr = @bitCast(cpu.fp.vpr), .it = it_state.get(cpu.regs.xpsr) };
}

test "mve_reduce matches the Arm ARM" {
    try vector.expectAll(vectors.In, vectors.Out, run, &vectors.all);
}

test "every vector is counted in covered and names the group" {
    try std.testing.expectEqual(vectors.all.len, vectors.covered.len);
    for (vectors.covered) |name| try std.testing.expectEqualStrings("mve_reduce", name);
}
