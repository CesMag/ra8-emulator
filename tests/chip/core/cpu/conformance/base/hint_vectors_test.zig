//! Covers src/chip/core/cpu/conformance/base/hint_vectors.zig: each vector runs
//! through the `hint` group on a bare M85 core with no exception source.
const std = @import("std");
const ra8 = @import("ra8");
const vector = ra8.chip.core.cpu.conformance.vector;
const vectors = ra8.chip.core.cpu.conformance.base.hint_vectors;
const cpu_ns = ra8.chip.core.cpu;
const bti_bit = cpu_ns.regs.xpsr_bits.bti;
const hint = cpu_ns.ops.hint;

fn run(in: vectors.In) vectors.Out {
    var cpu: cpu_ns.cpu.Cpu = .{ .bus = undefined, .regs = .{ .xpsr = cpu_ns.regs.xpsr_bits.thumb } };
    cpu.event = in.event;
    if (in.bti) cpu.regs.xpsr |= bti_bit;
    const instr: cpu_ns.instr.Instr = .{ .address = 0x1000, .hw1 = in.hw1, .hw2 = in.hw2, .size = @intCast(in.size) };
    const exec = hint.group.decode(instr) orelse return .{ .claimed = false };
    exec(&cpu, instr) catch return .{ .claimed = false, .event = true, .waiting = true, .bti = true };
    return .{
        .event = cpu.event,
        .waiting = cpu.waiting != null,
        .bti = cpu.regs.xpsr & bti_bit != 0,
    };
}

test "hint matches the Arm ARM" {
    try vector.expectAll(vectors.In, vectors.Out, run, &vectors.all);
}

test "every vector is counted in covered and names the group" {
    try std.testing.expectEqual(vectors.all.len, vectors.covered.len);
    for (vectors.covered) |name| try std.testing.expectEqualStrings("hint", name);
}
