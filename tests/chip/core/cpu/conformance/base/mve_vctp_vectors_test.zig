//! Covers src/chip/core/cpu/conformance/base/mve_vctp_vectors.zig: each vector
//! runs through the `mve_vctp` group with Rn, VPR, the IT byte, LR and
//! FPSCR.LTPSIZE set first.
const std = @import("std");
const ra8 = @import("ra8");
const vector = ra8.chip.core.cpu.conformance_vector;
const vectors = ra8.chip.core.cpu.conformance_base.mve_vctp_vectors;
const cpu_ns = ra8.chip.core.cpu;
const Cpu = cpu_ns.cpu.Cpu;
const it_state = cpu_ns.it_state;

fn run(in: vectors.In) vectors.Out {
    var cpu: Cpu = .{ .bus = undefined };
    cpu.fp.vpr = @bitCast(in.vpr);
    cpu.fp.fpscr.ltpsize = in.ltpsize;
    cpu.regs.xpsr = it_state.put(cpu.regs.xpsr, in.it);
    cpu.regs.set(14, in.lr);
    const rn: u4 = @intCast(in.hw1 & 0xF);
    if (rn != 13 and rn != 15) cpu.regs.set(rn, in.rn);
    const instr: cpu_ns.instr.Instr = .{ .address = 0x100, .hw1 = in.hw1, .hw2 = in.hw2, .size = @intCast(in.size) };
    const exec = cpu_ns.ops.mve_vctp.group.decode(instr) orelse return vectors.none;
    exec(&cpu, instr) catch unreachable;
    return .{ .vpr = @bitCast(cpu.fp.vpr), .it = it_state.get(cpu.regs.xpsr) };
}

test "mve_vctp matches the Arm ARM" {
    try vector.expectAll(vectors.In, vectors.Out, run, &vectors.all);
}

test "every vector is counted in covered and names the group" {
    try std.testing.expectEqual(vectors.all.len, vectors.covered.len);
    for (vectors.covered) |name| try std.testing.expectEqualStrings("mve_vctp", name);
}
