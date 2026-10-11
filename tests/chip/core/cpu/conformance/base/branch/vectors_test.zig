//! Covers src/chip/core/cpu/conformance/base/branch_vectors.zig: each vector
//! runs through the `branch` group on a bare register file.
const std = @import("std");
const ra8 = @import("ra8");
const vector = ra8.chip.core.cpu.conformance.vector;
const vectors = ra8.chip.core.cpu.conformance.base.branch.vectors;
const cpu_ns = ra8.chip.core.cpu;
const branch = cpu_ns.ops.branch;

fn run(in: vectors.In) vectors.Out {
    var cpu: cpu_ns.cpu.Cpu = .{ .bus = undefined, .regs = .{ .xpsr = cpu_ns.regs.xpsr_bits.thumb } };
    cpu.regs.xpsr |= @as(u32, in.nzcv) << 28;
    cpu.regs.pc = vectors.next;
    const instr: cpu_ns.instr.Instr = .{ .address = vectors.address, .hw1 = in.hw1, .size = 2 };
    const exec = branch.group.decode(instr) orelse return .{ .claimed = false };
    exec(&cpu, instr) catch return .{ .pc = 0xBAD0_BAD0 };
    return .{ .pc = cpu.regs.pc };
}

test "branch matches the Arm ARM" {
    try vector.expectAll(vectors.In, vectors.Out, run, &vectors.all);
}

test "every vector is counted in covered and names the group" {
    try std.testing.expectEqual(vectors.all.len, vectors.covered.len);
    for (vectors.covered) |name| try std.testing.expectEqualStrings("branch", name);
}
