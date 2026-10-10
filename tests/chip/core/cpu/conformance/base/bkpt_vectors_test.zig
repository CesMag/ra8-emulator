//! Covers src/chip/core/cpu/conformance/base/bkpt_vectors.zig: each vector runs
//! through the `bkpt` group.
const std = @import("std");
const ra8 = @import("ra8");
const vector = ra8.chip.core.cpu.conformance_vector;
const vectors = ra8.chip.core.cpu.conformance_base.bkpt_vectors;
const cpu_ns = ra8.chip.core.cpu;
const bkpt = cpu_ns.ops.bkpt;

fn run(in: vectors.In) vectors.Out {
    var cpu: cpu_ns.cpu.Cpu = .{ .bus = undefined, .regs = .{ .xpsr = cpu_ns.regs.xpsr_bits.thumb } };
    const instr: cpu_ns.instr.Instr = .{ .address = 0x1000, .hw1 = in.hw1, .size = 2 };
    const exec = bkpt.group.decode(instr) orelse return .{ .claimed = false };
    exec(&cpu, instr) catch |err| return .{ .breakpoint = err == error.Breakpoint };
    return .{};
}

test "bkpt matches the Arm ARM" {
    try vector.expectAll(vectors.In, vectors.Out, run, &vectors.all);
}

test "every vector is counted in covered and names the group" {
    try std.testing.expectEqual(vectors.all.len, vectors.covered.len);
    for (vectors.covered) |name| try std.testing.expectEqualStrings("bkpt", name);
}
