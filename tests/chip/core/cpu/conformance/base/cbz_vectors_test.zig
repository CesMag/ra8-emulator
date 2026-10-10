//! Covers src/chip/core/cpu/conformance/base/cbz_vectors.zig: each vector runs
//! through the `cbz` group on a bare register file.
const std = @import("std");
const ra8 = @import("ra8");
const vector = ra8.chip.core.cpu.conformance_vector;
const vectors = ra8.chip.core.cpu.conformance_base.cbz_vectors;
const cpu_ns = ra8.chip.core.cpu;
const cbz = cpu_ns.ops.cbz;

fn run(in: vectors.In) vectors.Out {
    var cpu: cpu_ns.cpu.Cpu = .{ .bus = undefined, .regs = .{ .xpsr = cpu_ns.regs.xpsr_bits.thumb } };
    cpu.regs.xpsr |= @as(u32, in.nzcv) << 28;
    cpu.regs.pc = vectors.next;
    cpu.regs.set(@intCast(in.hw1 & 0x7), in.rn);
    const instr: cpu_ns.instr.Instr = .{ .address = vectors.address, .hw1 = in.hw1, .size = 2 };
    const exec = cbz.group.decode(instr) orelse return .{ .claimed = false };
    exec(&cpu, instr) catch return .{ .pc = 0xBAD0_BAD0 };
    return .{ .pc = cpu.regs.pc, .nzcv = @intCast(cpu.regs.xpsr >> 28) };
}

test "cbz and cbnz match the Arm ARM" {
    try vector.expectAll(vectors.In, vectors.Out, run, &vectors.all);
}

test "every vector is counted in covered and names the group" {
    try std.testing.expectEqual(vectors.all.len, vectors.covered.len);
    for (vectors.covered) |name| try std.testing.expectEqualStrings("cbz", name);
}
