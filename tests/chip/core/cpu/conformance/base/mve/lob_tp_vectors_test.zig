//! Covers src/chip/core/cpu/conformance/base/mve/lob_tp_vectors.zig: each vector
//! runs through the `mve_lob_tp` group at 0x100 with Rn, LR and
//! FPSCR.LTPSIZE set first.
const std = @import("std");
const ra8 = @import("ra8");
const vector = ra8.chip.core.cpu.conformance.vector;
const vectors = ra8.chip.core.cpu.conformance.base.mve.lob_tp_vectors;
const cpu_ns = ra8.chip.core.cpu;
const Cpu = cpu_ns.cpu.Cpu;

fn run(in: vectors.In) vectors.Out {
    var cpu: Cpu = .{ .bus = undefined };
    cpu.regs.lr = in.lr;
    cpu.regs.pc = 0x100;
    cpu.fp.fpscr.ltpsize = in.ltpsize;
    const rn: u4 = @intCast(in.hw1 & 0xF);
    if (rn != 13 and rn != 14 and rn != 15) cpu.regs.set(rn, in.rn);
    const instr: cpu_ns.instr.Instr = .{ .address = 0x100, .hw1 = in.hw1, .hw2 = in.hw2, .size = @intCast(in.size) };
    const exec = cpu_ns.ops.mve.lob_tp.group.decode(instr) orelse return vectors.none;
    exec(&cpu, instr) catch unreachable;
    return .{ .pc = cpu.regs.pc, .lr = cpu.regs.lr, .ltpsize = cpu.fp.fpscr.ltpsize };
}

test "mve_lob_tp matches the Arm ARM" {
    try vector.expectAll(vectors.In, vectors.Out, run, &vectors.all);
}

test "every vector is counted in covered and names the group" {
    try std.testing.expectEqual(vectors.all.len, vectors.covered.len);
    for (vectors.covered) |name| try std.testing.expectEqualStrings("mve_lob_tp", name);
}
