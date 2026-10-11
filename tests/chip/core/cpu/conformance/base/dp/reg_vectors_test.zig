//! Covers src/chip/core/cpu/conformance/base/dp_reg_vectors.zig: each vector
//! runs through the `dp_reg` group on a bare register file, Rdn r0, Rm r1.
const std = @import("std");
const ra8 = @import("ra8");
const vector = ra8.chip.core.cpu.conformance.vector;
const vectors = ra8.chip.core.cpu.conformance.base.dp.reg_vectors;
const cpu_ns = ra8.chip.core.cpu;
const dp_reg = cpu_ns.ops.dp.reg;

fn run(in: vectors.In) vectors.Out {
    var cpu: cpu_ns.cpu.Cpu = .{ .bus = undefined, .regs = .{ .xpsr = cpu_ns.regs.xpsr_bits.thumb } };
    cpu.regs.xpsr |= @as(u32, in.nzcv) << 28;
    cpu.regs.xpsr = cpu_ns.it_state.put(cpu.regs.xpsr, in.it);
    const rdn: u4 = @intCast(in.hw1 & 0x7);
    cpu.regs.set(@intCast((in.hw1 >> 3) & 0x7), in.rm);
    cpu.regs.set(rdn, in.rdn);
    const instr: cpu_ns.instr.Instr = .{ .address = 0, .hw1 = in.hw1, .size = 2 };
    const exec = dp_reg.group.decode(instr) orelse return .{ .rd = 0xDEAD_DEAD, .nzcv = 0 };
    exec(&cpu, instr) catch return .{ .rd = 0xBAD0_BAD0, .nzcv = 0 };
    return .{ .rd = cpu.regs.get(rdn), .nzcv = @intCast(cpu.regs.xpsr >> 28) };
}

test "dp_reg matches Shift_C and AddWithCarry" {
    try vector.expectAll(vectors.In, vectors.Out, run, &vectors.all);
}

test "every vector is counted in covered and names the group" {
    try std.testing.expectEqual(vectors.all.len, vectors.covered.len);
    for (vectors.covered) |name| try std.testing.expectEqualStrings("dp_reg", name);
}
