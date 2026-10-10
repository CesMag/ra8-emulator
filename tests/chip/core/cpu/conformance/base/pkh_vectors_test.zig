//! Covers src/chip/core/cpu/conformance/base/pkh_vectors.zig: each vector
//! runs through the `pkh` group on a bare core holding N and C.
const std = @import("std");
const ra8 = @import("ra8");
const vector = ra8.chip.core.cpu.conformance.vector;
const vectors = ra8.chip.core.cpu.conformance.base.pkh_vectors;
const cpu_ns = ra8.chip.core.cpu;
const Cpu = cpu_ns.cpu.Cpu;
const nzcv: u32 = 0xF000_0000;

fn put(cpu: *Cpu, n: u4, value: u32) void {
    if (n != 13 and n != 15) cpu.regs.set(n, value);
}

fn run(in: vectors.In) vectors.Out {
    const xpsr = cpu_ns.regs.xpsr_bits.thumb | vectors.flags;
    var cpu: Cpu = .{ .bus = undefined, .regs = .{ .xpsr = xpsr } };
    put(&cpu, @intCast(in.hw1 & 0xF), in.n);
    put(&cpu, @intCast(in.hw2 & 0xF), in.m);
    const instr: cpu_ns.instr.Instr = .{ .address = 0x1000, .hw1 = in.hw1, .hw2 = in.hw2, .size = @intCast(in.size) };
    const exec = cpu_ns.ops.pkh.group.decode(instr) orelse return .{ .claimed = false, .flags = 0 };
    exec(&cpu, instr) catch return .{ .claimed = false, .rd = 1, .flags = 0 };
    const rd: u4 = @intCast((in.hw2 >> 8) & 0xF);
    return .{ .rd = cpu.regs.get(rd), .flags = cpu.regs.xpsr & nzcv };
}

test "pkh matches the Arm ARM" {
    try vector.expectAll(vectors.In, vectors.Out, run, &vectors.all);
}

test "every vector is counted in covered and names the group" {
    try std.testing.expectEqual(vectors.all.len, vectors.covered.len);
    for (vectors.covered) |name| try std.testing.expectEqualStrings("pkh", name);
}
