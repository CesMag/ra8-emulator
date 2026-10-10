//! Covers src/chip/core/cpu/conformance/base/mve_vcmp_vectors.zig: each vector
//! runs through the `mve_vcmp` group with Qn, Qm (vector forms only), Rm,
//! VPR, the IT byte, LR and FPSCR.LTPSIZE set first, then reads VPR and the
//! IT byte back.
const std = @import("std");
const ra8 = @import("ra8");
const vector = ra8.chip.core.cpu.conformance.vector;
const vectors = ra8.chip.core.cpu.conformance.base.mve_vcmp_vectors;
const cpu_ns = ra8.chip.core.cpu;
const Cpu = cpu_ns.cpu.Cpu;
const it_state = cpu_ns.it_state;

fn writeQ(cpu: *Cpu, n: u3, value: u128) void {
    for (0..4) |k| cpu.fp.bank.writeS(@as(u5, n) * 4 + @as(u5, @intCast(k)), @truncate(value >> @intCast(32 * k)));
}

fn run(in: vectors.In) vectors.Out {
    var cpu: Cpu = .{ .bus = undefined };
    writeQ(&cpu, @intCast(in.hw1 >> 1 & 7), in.qn);
    if (in.hw2 & 0x40 == 0) writeQ(&cpu, @intCast(in.hw2 >> 1 & 7), in.qm);
    cpu.fp.vpr = @bitCast(in.vpr);
    cpu.fp.fpscr.ltpsize = in.ltpsize;
    cpu.regs.xpsr = it_state.put(cpu.regs.xpsr, in.it);
    cpu.regs.set(14, in.lr);
    const rm: u4 = @intCast(in.hw2 & 0xF);
    if (in.hw2 & 0x40 != 0 and rm != 13 and rm != 15) cpu.regs.set(rm, in.rm);
    const instr: cpu_ns.instr.Instr = .{ .address = 0x100, .hw1 = in.hw1, .hw2 = in.hw2, .size = @intCast(in.size) };
    const exec = cpu_ns.ops.mve_vcmp.group.decode(instr) orelse return vectors.none;
    exec(&cpu, instr) catch unreachable;
    return .{ .vpr = @bitCast(cpu.fp.vpr), .it = it_state.get(cpu.regs.xpsr) };
}

test "mve_vcmp matches the Arm ARM" {
    try vector.expectAll(vectors.In, vectors.Out, run, &vectors.all);
}

test "every vector is counted in covered and names the group" {
    try std.testing.expectEqual(vectors.all.len, vectors.covered.len);
    for (vectors.covered) |name| try std.testing.expectEqualStrings("mve_vcmp", name);
}
