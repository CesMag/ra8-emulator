//! Covers src/chip/core/cpu/conformance/base/fp_arith_vectors.zig: each vector
//! runs through the `fp_arith` group with its accumulator and operands in
//! place and its FPSCR loaded.
const std = @import("std");
const ra8 = @import("ra8");
const vector = ra8.chip.core.cpu.conformance.vector;
const vectors = ra8.chip.core.cpu.conformance.base.fp_arith_vectors;
const cpu_ns = ra8.chip.core.cpu;
const Cpu = cpu_ns.cpu.Cpu;
const Fpscr = ra8.chip.core.cpu.fpu.fpscr.Fpscr;

fn put(cpu: *Cpu, double: bool, reg: u5, value: u64) void {
    if (double) cpu.fp.bank.writeD(@intCast(reg), value) else cpu.fp.bank.writeS(reg, @truncate(value));
}

fn run(in: vectors.In) vectors.Out {
    var cpu: Cpu = .{ .bus = undefined };
    cpu.fp.fpscr = @bitCast(in.fpscr);
    put(&cpu, in.double, in.d_reg, in.d);
    put(&cpu, in.double, in.n_reg, in.n);
    put(&cpu, in.double, in.m_reg, in.m);
    const instr: cpu_ns.instr.Instr = .{ .address = 0, .hw1 = in.hw1, .hw2 = in.hw2, .size = @intCast(in.size) };
    const exec = cpu_ns.ops.fp_arith.group.decode(instr) orelse return vectors.none;
    exec(&cpu, instr) catch return vectors.none;
    const dst: u64 = if (in.double) cpu.fp.bank.readD(@intCast(in.d_reg)) else cpu.fp.bank.readS(in.d_reg);
    return .{ .dst = dst, .fpscr = @as(Fpscr, cpu.fp.fpscr).bits() };
}

test "fp_arith matches the Arm ARM" {
    try vector.expectAll(vectors.In, vectors.Out, run, &vectors.all);
}

test "every vector is counted in covered and names the group" {
    try std.testing.expectEqual(vectors.all.len, vectors.covered.len);
    for (vectors.covered) |name| try std.testing.expectEqualStrings("fp_arith", name);
}
