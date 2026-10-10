//! Covers src/chip/core/cpu/conformance/base/parallel_vectors.zig: each vector runs
//! through the `parallel` group on a bare core holding N, C and the vector's GE.
const std = @import("std");
const ra8 = @import("ra8");
const vector = ra8.chip.core.cpu.conformance.vector;
const vectors = ra8.chip.core.cpu.conformance.base.parallel_vectors;
const cpu_ns = ra8.chip.core.cpu;
const Cpu = cpu_ns.cpu.Cpu;
const bits = cpu_ns.regs.xpsr_bits;
const nzcv: u32 = 0xF800_0000;

fn put(cpu: *Cpu, r: u4, value: u32) void {
    if (r != 13 and r != 15) cpu.regs.set(r, value);
}

fn run(in: vectors.In) vectors.Out {
    const xpsr = bits.thumb | vectors.flags | (@as(u32, in.ge) << bits.ge_shift);
    var cpu: Cpu = .{ .bus = undefined, .regs = .{ .xpsr = xpsr } };
    put(&cpu, @intCast(in.hw1 & 0xF), in.n);
    put(&cpu, @intCast(in.hw2 & 0xF), in.m);
    const instr: cpu_ns.instr.Instr = .{ .address = 0x1000, .hw1 = in.hw1, .hw2 = in.hw2, .size = @intCast(in.size) };
    const exec = cpu_ns.ops.parallel.group.decode(instr) orelse return .{ .claimed = false, .flags = 0 };
    exec(&cpu, instr) catch return .{ .claimed = false, .rd = 1, .flags = 0 };
    const rd: u4 = @intCast((in.hw2 >> 8) & 0xF);
    const ge: u4 = @truncate(cpu.regs.xpsr >> bits.ge_shift);
    return .{ .rd = cpu.regs.get(rd), .flags = cpu.regs.xpsr & nzcv, .ge = ge };
}

test "parallel matches the Arm ARM" {
    try vector.expectAll(vectors.In, vectors.Out, run, &vectors.all);
}

test "every vector is counted in covered and names the group" {
    try std.testing.expectEqual(vectors.all.len, vectors.covered.len);
    for (vectors.covered) |name| try std.testing.expectEqualStrings("parallel", name);
}
