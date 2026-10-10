//! Covers src/chip/core/cpu/conformance/base/dsp_long_mul_vectors.zig: each vector
//! runs through the `dsp_long_mul` group on a bare core holding N and C.
const std = @import("std");
const ra8 = @import("ra8");
const vector = ra8.chip.core.cpu.conformance_vector;
const vectors = ra8.chip.core.cpu.conformance_base.dsp_long_mul_vectors;
const cpu_ns = ra8.chip.core.cpu;
const nzcv: u32 = 0xF000_0000;

fn settable(n: u4) bool {
    return n != 13 and n != 15;
}

fn put(cpu: *cpu_ns.cpu.Cpu, n: u4, value: u32) void {
    if (settable(n)) cpu.regs.set(n, value);
}

fn run(in: vectors.In) vectors.Out {
    const xpsr = cpu_ns.regs.xpsr_bits.thumb | vectors.flags;
    var cpu: cpu_ns.cpu.Cpu = .{ .bus = undefined, .regs = .{ .xpsr = xpsr } };
    const lo: u4 = @intCast(in.hw2 >> 12);
    const hi: u4 = @intCast((in.hw2 >> 8) & 0xF);
    put(&cpu, lo, in.lo);
    put(&cpu, hi, in.hi);
    put(&cpu, @intCast(in.hw1 & 0xF), in.n);
    put(&cpu, @intCast(in.hw2 & 0xF), in.m);
    const instr: cpu_ns.instr.Instr = .{ .address = 0x1000, .hw1 = in.hw1, .hw2 = in.hw2, .size = @intCast(in.size) };
    const exec = cpu_ns.ops.dsp_long_mul.group.decode(instr) orelse return .{ .claimed = false, .flags = 0 };
    exec(&cpu, instr) catch return .{ .claimed = false, .lo = 1, .flags = 0 };
    return .{ .lo = cpu.regs.get(lo), .hi = cpu.regs.get(hi), .flags = cpu.regs.xpsr & nzcv };
}

test "dsp_long_mul matches the Arm ARM" {
    try vector.expectAll(vectors.In, vectors.Out, run, &vectors.all);
}

test "every vector is counted in covered and names the group" {
    try std.testing.expectEqual(vectors.all.len, vectors.covered.len);
    for (vectors.covered) |name| try std.testing.expectEqualStrings("dsp_long_mul", name);
}
