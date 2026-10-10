//! Covers src/chip/core/cpu/conformance/base/lob_vectors.zig: each vector runs
//! through the `lob` group with its count in R0 or R12, its LR, and its FP
//! context state.
const std = @import("std");
const ra8 = @import("ra8");
const vector = ra8.chip.core.cpu.conformance.vector;
const vectors = ra8.chip.core.cpu.conformance.base.lob_vectors;
const cpu_ns = ra8.chip.core.cpu;
const Cpu = cpu_ns.cpu.Cpu;
const fixture = @import("../../exception/ram.zig");

fn run(in: vectors.In) vectors.Out {
    var ram: fixture.Ram = .{};
    var cpu: Cpu = .{ .bus = ram.view(), .regs = .{ .xpsr = vectors.xpsr_in } };
    cpu.regs.pc = vectors.pc_in;
    cpu.regs.set(0, in.rn);
    cpu.regs.set(12, in.rn);
    cpu.regs.lr = in.lr;
    if (in.fpca) cpu.regs.control |= cpu_ns.regs.control_bits.fpca;
    cpu.fp.fpscr.ltpsize = in.ltpsize;
    const instr: cpu_ns.instr.Instr = .{ .address = vectors.pc_in, .hw1 = in.hw1, .hw2 = in.hw2, .size = @intCast(in.size) };
    const exec = cpu_ns.ops.lob.group.decode(instr) orelse return vectors.none;
    const ended: vectors.Fault = if (exec(&cpu, instr)) .none else |err| if (err == error.InvalidState) .invalid_state else .other;
    return .{ .fault = ended, .pc = cpu.regs.pc, .lr = cpu.regs.lr, .xpsr = cpu.regs.xpsr };
}

test "lob matches the Arm ARM" {
    try vector.expectAll(vectors.In, vectors.Out, run, &vectors.all);
}

test "every vector is counted in covered and names the group" {
    try std.testing.expectEqual(vectors.all.len, vectors.covered.len);
    for (vectors.covered) |name| try std.testing.expectEqualStrings("lob", name);
}
