//! Covers src/chip/core/cpu/conformance/base/add_sub_vectors.zig: each vector
//! runs through the `add_sub` group on a bare register file.
const std = @import("std");
const ra8 = @import("ra8");
const vector = ra8.chip.core.cpu.conformance.vector;
const vectors = ra8.chip.core.cpu.conformance.base.add.sub.vectors;
const cpu_ns = ra8.chip.core.cpu;
const add_sub = cpu_ns.ops.add.sub;

/// The three-operand forms (T1 ADD/SUB register and imm3) sit at 0x18xx-0x1Fxx.
fn threeOperand(hw1: u16) bool {
    return hw1 & 0xF800 == 0x1800;
}

fn run(in: vectors.In) vectors.Out {
    var cpu: cpu_ns.cpu.Cpu = .{ .bus = undefined, .regs = .{ .xpsr = cpu_ns.regs.xpsr_bits.thumb } };
    cpu.regs.xpsr |= @as(u32, in.nzcv) << 28;
    cpu.regs.xpsr = cpu_ns.it_state.put(cpu.regs.xpsr, in.it);
    var rd: u4 = undefined;
    if (threeOperand(in.hw1)) {
        if (in.hw1 & 0x0400 == 0) cpu.regs.set(@intCast((in.hw1 >> 6) & 0x7), in.rm);
        cpu.regs.set(@intCast((in.hw1 >> 3) & 0x7), in.rn);
        rd = @intCast(in.hw1 & 0x7);
    } else {
        rd = @intCast((in.hw1 >> 8) & 0x7);
        cpu.regs.set(rd, in.rn);
    }
    const instr: cpu_ns.instr.Instr = .{ .address = 0, .hw1 = in.hw1, .size = 2 };
    const exec = add_sub.group.decode(instr) orelse return .{ .rd = 0xDEAD_DEAD, .nzcv = 0 };
    exec(&cpu, instr) catch return .{ .rd = 0xBAD0_BAD0, .nzcv = 0 };
    return .{ .rd = cpu.regs.get(rd), .nzcv = @intCast(cpu.regs.xpsr >> 28) };
}

test "add_sub matches AddWithCarry" {
    try vector.expectAll(vectors.In, vectors.Out, run, &vectors.all);
}

test "every vector is counted in covered and names the group" {
    try std.testing.expectEqual(vectors.all.len, vectors.covered.len);
    for (vectors.covered) |name| try std.testing.expectEqualStrings("add_sub", name);
}
