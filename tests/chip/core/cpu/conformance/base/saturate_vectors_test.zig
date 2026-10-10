//! Covers src/chip/core/cpu/conformance/base/saturate_vectors.zig: each vector
//! runs through the `saturate` group on a bare core holding N and C.
const std = @import("std");
const ra8 = @import("ra8");
const vector = ra8.chip.core.cpu.conformance_vector;
const vectors = ra8.chip.core.cpu.conformance_base.saturate_vectors;
const cpu_ns = ra8.chip.core.cpu;
const nzcvq: u32 = 0xF800_0000;

fn run(in: vectors.In) vectors.Out {
    const xpsr = cpu_ns.regs.xpsr_bits.thumb | vectors.flags;
    var cpu: cpu_ns.cpu.Cpu = .{ .bus = undefined, .regs = .{ .xpsr = xpsr } };
    const rn: u4 = @intCast(in.hw1 & 0xF);
    if (rn != 13 and rn != 15) cpu.regs.set(rn, in.n);
    const instr: cpu_ns.instr.Instr = .{ .address = 0x1000, .hw1 = in.hw1, .hw2 = in.hw2, .size = @intCast(in.size) };
    const exec = cpu_ns.ops.saturate.group.decode(instr) orelse return .{ .claimed = false, .flags = 0 };
    exec(&cpu, instr) catch return .{ .claimed = false, .rd = 1, .flags = 0 };
    const rd: u4 = @intCast((in.hw2 >> 8) & 0xF);
    return .{ .rd = cpu.regs.get(rd), .flags = cpu.regs.xpsr & nzcvq };
}

test "saturate matches the Arm ARM" {
    try vector.expectAll(vectors.In, vectors.Out, run, &vectors.all);
}

test "the Q bit matches the core's" {
    try std.testing.expectEqual(cpu_ns.regs.xpsr_bits.q, vectors.q);
}

test "every vector is counted in covered and names the group" {
    try std.testing.expectEqual(vectors.all.len, vectors.covered.len);
    for (vectors.covered) |name| try std.testing.expectEqualStrings("saturate", name);
}
