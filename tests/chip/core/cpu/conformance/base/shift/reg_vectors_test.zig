//! Covers src/chip/core/cpu/conformance/base/shift_reg_vectors.zig: each vector
//! runs through the `shift_reg` group on a bare core.
const std = @import("std");
const ra8 = @import("ra8");
const vector = ra8.chip.core.cpu.conformance.vector;
const vectors = ra8.chip.core.cpu.conformance.base.shift.reg_vectors;
const cpu_ns = ra8.chip.core.cpu;
const nzcv: u32 = 0xF000_0000;

fn settable(n: u4) bool {
    return n != 13 and n != 15;
}

fn run(in: vectors.In) vectors.Out {
    const xpsr = cpu_ns.regs.xpsr_bits.thumb | in.flags;
    var cpu: cpu_ns.cpu.Cpu = .{ .bus = undefined, .regs = .{ .xpsr = xpsr } };
    const rd: u4 = @intCast((in.hw2 >> 8) & 0xF);
    const rn: u4 = @intCast(in.hw1 & 0xF);
    const rm: u4 = @intCast(in.hw2 & 0xF);
    if (settable(rn)) cpu.regs.set(rn, in.n);
    if (settable(rm)) cpu.regs.set(rm, in.m);
    const instr: cpu_ns.instr.Instr = .{ .address = 0x1000, .hw1 = in.hw1, .hw2 = in.hw2, .size = @intCast(in.size) };
    const exec = cpu_ns.ops.shift.reg.group.decode(instr) orelse return .{ .claimed = false, .flags = 0 };
    exec(&cpu, instr) catch return .{ .claimed = false, .rd = 1, .flags = 0 };
    return .{ .rd = cpu.regs.get(rd), .flags = cpu.regs.xpsr & nzcv };
}

test "shift_reg matches the Arm ARM" {
    try vector.expectAll(vectors.In, vectors.Out, run, &vectors.all);
}

test "every vector is counted in covered and names the group" {
    try std.testing.expectEqual(vectors.all.len, vectors.covered.len);
    for (vectors.covered) |name| try std.testing.expectEqualStrings("shift_reg", name);
}
