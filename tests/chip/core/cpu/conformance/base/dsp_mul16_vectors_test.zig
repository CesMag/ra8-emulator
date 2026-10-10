//! Covers src/chip/core/cpu/conformance/base/dsp_mul16_vectors.zig: each vector
//! runs through the `dsp_mul16` group on a bare core holding N, C and the
//! vector's Q.
const std = @import("std");
const ra8 = @import("ra8");
const vector = ra8.chip.core.cpu.conformance.vector;
const vectors = ra8.chip.core.cpu.conformance.base.dsp_mul16_vectors;
const cpu_ns = ra8.chip.core.cpu;
const Cpu = cpu_ns.cpu.Cpu;
const bits = cpu_ns.regs.xpsr_bits;
const nzcvq: u32 = 0xF800_0000;

fn put(cpu: *Cpu, r: u4, value: u32) void {
    if (r != 13 and r != 15) cpu.regs.set(r, value);
}

fn run(in: vectors.In) vectors.Out {
    const q: u32 = if (in.q) bits.q else 0;
    var cpu: Cpu = .{ .bus = undefined, .regs = .{ .xpsr = bits.thumb | vectors.flags | q } };
    put(&cpu, @intCast(in.hw2 >> 12), in.a);
    put(&cpu, @intCast(in.hw1 & 0xF), in.n);
    put(&cpu, @intCast(in.hw2 & 0xF), in.m);
    const instr: cpu_ns.instr.Instr = .{ .address = 0x1000, .hw1 = in.hw1, .hw2 = in.hw2, .size = @intCast(in.size) };
    const exec = cpu_ns.ops.dsp_mul16.group.decode(instr) orelse return .{ .claimed = false, .flags = 0 };
    exec(&cpu, instr) catch return .{ .claimed = false, .rd = 1, .flags = 0 };
    const rd: u4 = @intCast((in.hw2 >> 8) & 0xF);
    return .{ .rd = cpu.regs.get(rd), .flags = cpu.regs.xpsr & nzcvq };
}

test "dsp_mul16 matches the Arm ARM" {
    try vector.expectAll(vectors.In, vectors.Out, run, &vectors.all);
}

test "every vector is counted in covered and names the group" {
    try std.testing.expectEqual(vectors.all.len, vectors.covered.len);
    for (vectors.covered) |name| try std.testing.expectEqualStrings("dsp_mul16", name);
}
