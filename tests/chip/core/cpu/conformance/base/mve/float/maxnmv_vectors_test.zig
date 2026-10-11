//! Covers src/chip/core/cpu/conformance/base/mve/float/maxnmv_vectors.zig: each
//! vector runs through the `mve_float_maxnmv` group with Qm, LR, Rda (after
//! LR, so Rda = LR holds), VPR and FPSCR set first, then reads Rda, FPSCR
//! and VPR back.
const std = @import("std");
const ra8 = @import("ra8");
const vector = ra8.chip.core.cpu.conformance.vector;
const vectors = ra8.chip.core.cpu.conformance.base.mve.float.maxnmv_vectors;
const cpu_ns = ra8.chip.core.cpu;
const Cpu = cpu_ns.cpu.Cpu;

fn writeQ(cpu: *Cpu, n: u3, value: u128) void {
    for (0..4) |k| cpu.fp.bank.writeS(@as(u5, n) * 4 + @as(u5, @intCast(k)), @truncate(value >> @intCast(32 * k)));
}

fn run(in: vectors.In) vectors.Out {
    var cpu: Cpu = .{ .bus = undefined };
    writeQ(&cpu, @intCast(in.hw2 >> 1 & 7), in.qm);
    cpu.regs.set(14, in.lr);
    const rda: u4 = @intCast(in.hw2 >> 12);
    if (rda != 13 and rda != 15) cpu.regs.set(rda, in.rda);
    cpu.fp.vpr = @bitCast(in.vpr);
    cpu.fp.fpscr = @bitCast(in.fpscr);
    const instr: cpu_ns.instr.Instr = .{ .address = 0x100, .hw1 = in.hw1, .hw2 = in.hw2, .size = @intCast(in.size) };
    const exec = cpu_ns.ops.mve.float.maxnmv.group.decode(instr) orelse return vectors.none;
    exec(&cpu, instr) catch unreachable;
    return .{ .rda = cpu.regs.get(rda), .fpscr = @bitCast(cpu.fp.fpscr), .vpr = @bitCast(cpu.fp.vpr) };
}

test "mve_float_maxnmv matches the Arm ARM" {
    try vector.expectAll(vectors.In, vectors.Out, run, &vectors.all);
}

test "every vector is counted in covered and names the group" {
    try std.testing.expectEqual(vectors.all.len, vectors.covered.len);
    for (vectors.covered) |name| try std.testing.expectEqualStrings("mve_float_maxnmv", name);
}
