//! Covers src/chip/core/cpu/conformance/base/sp_arith_vectors.zig: each vector
//! runs through the `sp_arith` group on a bare core.
const std = @import("std");
const ra8 = @import("ra8");
const vector = ra8.chip.core.cpu.conformance_vector;
const vectors = ra8.chip.core.cpu.conformance_base.sp_arith_vectors;
const cpu_ns = ra8.chip.core.cpu;

fn run(in: vectors.In) vectors.Out {
    var cpu: cpu_ns.cpu.Cpu = .{ .bus = undefined, .regs = .{ .xpsr = cpu_ns.regs.xpsr_bits.thumb } };
    cpu.regs.xpsr |= @as(u32, in.nzcv) << 28;
    for (0..8) |n| cpu.regs.set(@intCast(n), vectors.fill);
    cpu.regs.setSp(in.sp);
    const instr: cpu_ns.instr.Instr = .{ .address = in.address, .hw1 = in.hw1, .size = @intCast(in.size) };
    const exec = cpu_ns.ops.sp_arith.group.decode(instr) orelse return .{ .claimed = false, .sp = 0, .rd = 0 };
    exec(&cpu, instr) catch return .{ .claimed = false, .sp = 1, .rd = 1 };
    return .{
        .sp = cpu.regs.sp(),
        .rd = cpu.regs.get(in.rd),
        .nzcv = @intCast(cpu.regs.xpsr >> 28),
    };
}

test "sp_arith matches the Arm ARM" {
    try vector.expectAll(vectors.In, vectors.Out, run, &vectors.all);
}

test "every vector is counted in covered and names the group" {
    try std.testing.expectEqual(vectors.all.len, vectors.covered.len);
    for (vectors.covered) |name| try std.testing.expectEqualStrings("sp_arith", name);
}
