//! Covers src/chip/core/cpu/conformance/base/mve_lane_pair_vectors.zig: each
//! vector runs through the `mve_lane_pair` group over a patterned FP bank
//! with Rt, Rt2, VPR and the IT byte set first.
const std = @import("std");
const ra8 = @import("ra8");
const vector = ra8.chip.core.cpu.conformance.vector;
const vectors = ra8.chip.core.cpu.conformance.base.mve_lane_pair_vectors;
const cpu_ns = ra8.chip.core.cpu;
const Cpu = cpu_ns.cpu.Cpu;
const it_state = cpu_ns.it_state;

fn readQ(cpu: *const Cpu, n: u3) u128 {
    var q: u128 = 0;
    var k: u5 = 4;
    while (k > 0) : (k -= 1) q = q << 32 | cpu.fp.bank.readS(@as(u5, n) * 4 + (k - 1));
    return q;
}

fn usable(r: u4) bool {
    return r != 13 and r != 15;
}

fn run(in: vectors.In) vectors.Out {
    var cpu: Cpu = .{ .bus = undefined };
    for (0..32) |i| cpu.fp.bank.writeS(@intCast(i), vectors.bankAt(@intCast(i)));
    cpu.fp.vpr = @bitCast(in.vpr);
    cpu.regs.xpsr = it_state.put(cpu.regs.xpsr, in.it);
    const rt: u4 = @intCast(in.hw2 & 0xF);
    const rt2: u4 = @intCast(in.hw1 & 0xF);
    if (usable(rt)) cpu.regs.set(rt, 0x1111_1111);
    if (usable(rt2)) cpu.regs.set(rt2, 0x2222_2222);
    const instr: cpu_ns.instr.Instr = .{ .address = 0x100, .hw1 = in.hw1, .hw2 = in.hw2, .size = @intCast(in.size) };
    const exec = cpu_ns.ops.mve_lane_pair.group.decode(instr) orelse return vectors.none;
    exec(&cpu, instr) catch unreachable;
    return .{
        .q = readQ(&cpu, @intCast(in.hw2 >> 13)),
        .rt = cpu.regs.get(rt),
        .rt2 = cpu.regs.get(rt2),
        .vpr = @bitCast(cpu.fp.vpr),
        .it = it_state.get(cpu.regs.xpsr),
    };
}

test "mve_lane_pair matches the Arm ARM" {
    try vector.expectAll(vectors.In, vectors.Out, run, &vectors.all);
}

test "every vector is counted in covered and names the group" {
    try std.testing.expectEqual(vectors.all.len, vectors.covered.len);
    for (vectors.covered) |name| try std.testing.expectEqualStrings("mve_lane_pair", name);
}
