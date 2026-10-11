//! Covers src/chip/core/cpu/conformance/base/fp_move_vectors.zig: each vector
//! runs through the `fp_move` group from the patterned core and FP banks.
const std = @import("std");
const ra8 = @import("ra8");
const vector = ra8.chip.core.cpu.conformance.vector;
const vectors = ra8.chip.core.cpu.conformance.base.fp.move_vectors;
const cpu_ns = ra8.chip.core.cpu;
const Cpu = cpu_ns.cpu.Cpu;

fn run(in: vectors.In) vectors.Out {
    var cpu: Cpu = .{ .bus = undefined };
    for (0..13) |i| cpu.regs.set(@intCast(i), vectors.coreAt(@intCast(i)));
    for (0..32) |i| cpu.fp.bank.writeS(@intCast(i), vectors.bankAt(@intCast(i)));
    const instr: cpu_ns.instr.Instr = .{ .address = 0, .hw1 = in.hw1, .hw2 = in.hw2, .size = @intCast(in.size) };
    const exec = cpu_ns.ops.fp.move.group.decode(instr) orelse return vectors.none;
    exec(&cpu, instr) catch return vectors.none;
    return .{
        .r1 = cpu.regs.get(1),
        .r2 = cpu.regs.get(2),
        .s_a = cpu.fp.bank.readS(in.watch),
        .s_b = cpu.fp.bank.readS(in.watch +% 1),
    };
}

test "fp_move matches the Arm ARM" {
    try vector.expectAll(vectors.In, vectors.Out, run, &vectors.all);
}

test "every vector is counted in covered and names the group" {
    try std.testing.expectEqual(vectors.all.len, vectors.covered.len);
    for (vectors.covered) |name| try std.testing.expectEqualStrings("fp_move", name);
}
