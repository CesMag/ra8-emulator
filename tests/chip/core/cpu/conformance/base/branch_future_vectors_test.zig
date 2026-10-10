//! Covers src/chip/core/cpu/conformance/base/branch_future_vectors.zig: each
//! vector runs through the `branch_future` group over the exception tests'
//! RAM and checks the state it leaves.
const std = @import("std");
const ra8 = @import("ra8");
const vector = ra8.chip.core.cpu.conformance_vector;
const vectors = ra8.chip.core.cpu.conformance_base.branch_future_vectors;
const cpu_ns = ra8.chip.core.cpu;
const Cpu = cpu_ns.cpu.Cpu;
const fixture = @import("../../exception/ram.zig");

fn run(in: vectors.In) vectors.Out {
    var ram: fixture.Ram = .{};
    var cpu: Cpu = .{ .bus = ram.view(), .regs = .{ .xpsr = vectors.xpsr_in } };
    cpu.regs.pc = vectors.pc_in;
    cpu.regs.set(14, vectors.lr_in);
    cpu.regs.set(3, vectors.r3_in);
    const instr: cpu_ns.instr.Instr = .{ .address = vectors.pc_in, .hw1 = in.hw1, .hw2 = in.hw2, .size = @intCast(in.size) };
    const none: vectors.Out = .{ .claimed = false, .pc = 0, .lr = 0, .r3 = 0, .xpsr = 0 };
    const exec = cpu_ns.ops.branch_future.group.decode(instr) orelse return none;
    exec(&cpu, instr) catch return none;
    return .{ .pc = cpu.regs.pc, .lr = cpu.regs.get(14), .r3 = cpu.regs.get(3), .xpsr = cpu.regs.xpsr };
}

test "branch_future matches the Arm ARM" {
    try vector.expectAll(vectors.In, vectors.Out, run, &vectors.all);
}

test "every vector is counted in covered and names the group" {
    try std.testing.expectEqual(vectors.all.len, vectors.covered.len);
    for (vectors.covered) |name| try std.testing.expectEqualStrings("branch_future", name);
}
