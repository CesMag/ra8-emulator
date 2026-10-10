//! Covers src/chip/core/cpu/conformance/base/mve_int_vectors.zig: each
//! vector runs through the `mve_int` group with Qd, Qn, Qm, VPR, the
//! IT byte, LR, FPSCR.LTPSIZE and FPSCR.QC set first.
const std = @import("std");
const ra8 = @import("ra8");
const vector = ra8.chip.core.cpu.conformance.vector;
const vectors = ra8.chip.core.cpu.conformance.base.mve_int_vectors;
const cpu_ns = ra8.chip.core.cpu;
const Cpu = cpu_ns.cpu.Cpu;
const it_state = cpu_ns.it_state;

fn writeQ(cpu: *Cpu, n: u3, value: u128) void {
    for (0..4) |k| cpu.fp.bank.writeS(@as(u5, n) * 4 + @as(u5, @intCast(k)), @truncate(value >> @intCast(32 * k)));
}

fn readQ(cpu: *const Cpu, n: u3) u128 {
    var q: u128 = 0;
    var k: u5 = 4;
    while (k > 0) : (k -= 1) q = q << 32 | cpu.fp.bank.readS(@as(u5, n) * 4 + (k - 1));
    return q;
}

fn run(in: vectors.In) vectors.Out {
    var cpu: Cpu = .{ .bus = undefined };
    const qd: u3 = @intCast(in.hw2 >> 13);
    writeQ(&cpu, qd, in.qd);
    writeQ(&cpu, @intCast(in.hw1 >> 1 & 7), in.qn);
    writeQ(&cpu, @intCast(in.hw2 >> 1 & 7), in.qm);
    cpu.fp.vpr = @bitCast(in.vpr);
    cpu.fp.fpscr.ltpsize = in.ltpsize;
    cpu.fp.fpscr.qc = in.qc;
    cpu.regs.xpsr = it_state.put(cpu.regs.xpsr, in.it);
    cpu.regs.set(14, in.lr);
    const instr: cpu_ns.instr.Instr = .{ .address = 0x100, .hw1 = in.hw1, .hw2 = in.hw2, .size = @intCast(in.size) };
    const exec = cpu_ns.ops.mve_int.group.decode(instr) orelse return vectors.none;
    exec(&cpu, instr) catch unreachable;
    return .{ .qd = readQ(&cpu, qd), .vpr = @bitCast(cpu.fp.vpr), .it = it_state.get(cpu.regs.xpsr), .qc = cpu.fp.fpscr.qc };
}

test "mve_int matches the Arm ARM" {
    try vector.expectAll(vectors.In, vectors.Out, run, &vectors.all);
}

test "every vector is counted in covered and names the group" {
    try std.testing.expectEqual(vectors.all.len, vectors.covered.len);
    for (vectors.covered) |name| try std.testing.expectEqualStrings("mve_int", name);
}
