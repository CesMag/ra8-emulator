//! Covers src/chip/core/cpu/conformance/base/barrier_vectors.zig: each vector
//! runs through the `barrier` group on a bare core holding N, C, Q and a
//! seeded r0 and r12.
const std = @import("std");
const ra8 = @import("ra8");
const vector = ra8.chip.core.cpu.conformance.vector;
const vectors = ra8.chip.core.cpu.conformance.base.barrier_vectors;
const cpu_ns = ra8.chip.core.cpu;
const Cpu = cpu_ns.cpu.Cpu;
const nzcvq: u32 = 0xF800_0000;

fn run(in: vectors.In) vectors.Out {
    var cpu: Cpu = .{ .bus = undefined, .regs = .{ .xpsr = cpu_ns.regs.xpsr_bits.thumb | vectors.flags } };
    cpu.regs.set(0, vectors.seed);
    cpu.regs.set(12, vectors.seed);
    const instr: cpu_ns.instr.Instr = .{ .address = 0x1000, .hw1 = in.hw1, .hw2 = in.hw2, .size = @intCast(in.size) };
    const exec = cpu_ns.ops.barrier.group.decode(instr) orelse return .{ .claimed = false, .r0 = 0, .r12 = 0, .flags = 0 };
    exec(&cpu, instr) catch return .{ .claimed = false, .r0 = 1, .r12 = 0, .flags = 0 };
    return .{ .r0 = cpu.regs.get(0), .r12 = cpu.regs.get(12), .flags = cpu.regs.xpsr & nzcvq };
}

test "barrier matches the Arm ARM" {
    try vector.expectAll(vectors.In, vectors.Out, run, &vectors.all);
}

test "every vector is counted in covered and names the group" {
    try std.testing.expectEqual(vectors.all.len, vectors.covered.len);
    for (vectors.covered) |name| try std.testing.expectEqualStrings("barrier", name);
}
