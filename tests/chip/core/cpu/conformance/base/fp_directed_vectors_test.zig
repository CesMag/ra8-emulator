//! Covers src/chip/core/cpu/conformance/base/fp_directed_vectors.zig: each
//! vector presets the destination to all ones, loads Sn/Dn, Sm/Dm, the
//! APSR flags and FPSCR, and runs the `fp_directed` group.
const std = @import("std");
const ra8 = @import("ra8");
const vector = ra8.chip.core.cpu.conformance.vector;
const vectors = ra8.chip.core.cpu.conformance.base.fp_directed_vectors;
const cpu_ns = ra8.chip.core.cpu;
const Cpu = cpu_ns.cpu.Cpu;
const Fpscr = ra8.chip.core.cpu.fpu.fpscr.Fpscr;

fn put(cpu: *Cpu, wide: bool, reg: u5, value: u64) void {
    if (wide) cpu.fp.bank.writeD(@intCast(reg), value) else cpu.fp.bank.writeS(reg, @truncate(value));
}

fn run(in: vectors.In) vectors.Out {
    var cpu: Cpu = .{ .bus = undefined };
    cpu.fp.fpscr = @bitCast(in.fpscr);
    cpu.regs.xpsr = in.xpsr;
    put(&cpu, in.dst_wide, in.d_reg, vectors.dst_reset);
    put(&cpu, in.double, in.n_reg, in.n);
    put(&cpu, in.double, in.m_reg, in.m);
    const instr: cpu_ns.instr.Instr = .{ .address = 0, .hw1 = in.hw1, .hw2 = in.hw2, .size = @intCast(in.size) };
    const exec = cpu_ns.ops.fp_directed.group.decode(instr) orelse return vectors.none;
    exec(&cpu, instr) catch return vectors.none;
    const dst: u64 = if (in.dst_wide) cpu.fp.bank.readD(@intCast(in.d_reg)) else cpu.fp.bank.readS(in.d_reg);
    return .{ .dst = dst, .fpscr = @as(Fpscr, cpu.fp.fpscr).bits() };
}

test "fp_directed matches the Arm ARM" {
    try vector.expectAll(vectors.In, vectors.Out, run, &vectors.all);
}

test "every vector is counted in covered and names the group" {
    try std.testing.expectEqual(vectors.all.len, vectors.covered.len);
    for (vectors.covered) |name| try std.testing.expectEqualStrings("fp_directed", name);
}
