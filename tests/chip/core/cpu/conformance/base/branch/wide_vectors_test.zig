//! Covers src/chip/core/cpu/conformance/base/branch_wide_vectors.zig: each
//! vector runs through the `branch_wide` group on a bare core whose PC and
//! LR hold sentinels.
const std = @import("std");
const ra8 = @import("ra8");
const vector = ra8.chip.core.cpu.conformance.vector;
const vectors = ra8.chip.core.cpu.conformance.base.branch.wide_vectors;
const cpu_ns = ra8.chip.core.cpu;
const Cpu = cpu_ns.cpu.Cpu;

fn run(in: vectors.In) vectors.Out {
    var cpu: Cpu = .{ .bus = undefined, .regs = .{
        .xpsr = cpu_ns.regs.xpsr_bits.thumb | in.flags,
        .pc = vectors.unmoved,
        .lr = vectors.lr_seed,
    } };
    const instr: cpu_ns.instr.Instr = .{ .address = in.address, .hw1 = in.hw1, .hw2 = in.hw2, .size = @intCast(in.size) };
    const exec = cpu_ns.ops.branch.wide.group.decode(instr) orelse return .{ .claimed = false, .pc = 0, .lr = 0 };
    exec(&cpu, instr) catch return .{ .claimed = false, .pc = 1, .lr = 0 };
    return .{ .pc = cpu.regs.pc, .lr = cpu.regs.lr };
}

test "branch_wide matches the Arm ARM" {
    try vector.expectAll(vectors.In, vectors.Out, run, &vectors.all);
}

test "every vector is counted in covered and names the group" {
    try std.testing.expectEqual(vectors.all.len, vectors.covered.len);
    for (vectors.covered) |name| try std.testing.expectEqualStrings("branch_wide", name);
}
