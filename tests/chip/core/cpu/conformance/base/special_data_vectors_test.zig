//! Covers src/chip/core/cpu/conformance/base/special_data_vectors.zig: each
//! vector runs through the `special_data` group on a bare register file in
//! Thread mode.
const std = @import("std");
const ra8 = @import("ra8");
const vector = ra8.chip.core.cpu.conformance.vector;
const vectors = ra8.chip.core.cpu.conformance.base.special_data_vectors;
const cpu_ns = ra8.chip.core.cpu;
const special_data = cpu_ns.ops.special_data;

fn run(in: vectors.In) vectors.Out {
    var cpu: cpu_ns.cpu.Cpu = .{ .bus = undefined, .regs = .{ .xpsr = cpu_ns.regs.xpsr_bits.thumb } };
    cpu.regs.xpsr |= @as(u32, in.nzcv) << 28;
    cpu.regs.pc = vectors.next;
    const first: u4 = @intCast(((in.hw1 >> 4) & 0x8) | (in.hw1 & 0x7));
    const second: u4 = @intCast((in.hw1 >> 3) & 0xF);
    if (first != 15) cpu.regs.set(first, in.first);
    if (second != 15) cpu.regs.set(second, in.second);
    const instr: cpu_ns.instr.Instr = .{ .address = vectors.address, .hw1 = in.hw1, .size = 2 };
    const exec = special_data.group.decode(instr) orelse return .{ .claimed = false };
    exec(&cpu, instr) catch return .{ .first = 0xBAD0_BAD0 };
    return .{
        .first = if (first == 15) 0 else cpu.regs.get(first),
        .pc = cpu.regs.pc,
        .lr = cpu.regs.lr,
        .nzcv = @intCast(cpu.regs.xpsr >> 28),
        .thumb = cpu.regs.xpsr & cpu_ns.regs.xpsr_bits.thumb != 0,
    };
}

test "special_data matches the Arm ARM" {
    try vector.expectAll(vectors.In, vectors.Out, run, &vectors.all);
}

test "every vector is counted in covered and names the group" {
    try std.testing.expectEqual(vectors.all.len, vectors.covered.len);
    for (vectors.covered) |name| try std.testing.expectEqualStrings("special_data", name);
}
