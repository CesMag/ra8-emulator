//! Covers src/chip/core/cpu/conformance/base/reverse_vectors.zig: each vector runs
//! through the `reverse` group on a bare register file.
const std = @import("std");
const ra8 = @import("ra8");
const vector = ra8.chip.core.cpu.conformance.vector;
const vectors = ra8.chip.core.cpu.conformance.base.reverse_vectors;
const cpu_ns = ra8.chip.core.cpu;
const reverse = cpu_ns.ops.reverse;

fn run(in: vectors.In) vectors.Out {
    var cpu: cpu_ns.cpu.Cpu = .{ .bus = undefined, .regs = .{ .xpsr = cpu_ns.regs.xpsr_bits.thumb } };
    cpu.regs.xpsr |= @as(u32, in.nzcv) << 28;
    const rd: u4 = @intCast(in.hw1 & 0x7);
    cpu.regs.set(rd, 0x5555_5555);
    cpu.regs.set(@intCast((in.hw1 >> 3) & 0x7), in.rm);
    const instr: cpu_ns.instr.Instr = .{ .address = 0, .hw1 = in.hw1, .size = 2 };
    const exec = reverse.group.decode(instr) orelse return .{ .claimed = false, .rd = 0, .nzcv = 0 };
    exec(&cpu, instr) catch return .{ .rd = 0xBAD0_BAD0, .nzcv = 0 };
    return .{ .rd = cpu.regs.get(rd), .nzcv = @intCast(cpu.regs.xpsr >> 28) };
}

test "reverse matches the Arm ARM" {
    try vector.expectAll(vectors.In, vectors.Out, run, &vectors.all);
}

test "every vector is counted in covered and names the group" {
    try std.testing.expectEqual(vectors.all.len, vectors.covered.len);
    for (vectors.covered) |name| try std.testing.expectEqualStrings("reverse", name);
}
