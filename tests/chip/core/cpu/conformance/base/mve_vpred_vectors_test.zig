//! Covers src/chip/core/cpu/conformance/base/mve_vpred_vectors.zig: each vector
//! runs through the `mve_vpred` group over a patterned FP bank with VPR,
//! the IT byte, LR and FPSCR.LTPSIZE set first.
const std = @import("std");
const ra8 = @import("ra8");
const vector = ra8.chip.core.cpu.conformance_vector;
const vectors = ra8.chip.core.cpu.conformance_base.mve_vpred_vectors;
const cpu_ns = ra8.chip.core.cpu;
const Cpu = cpu_ns.cpu.Cpu;
const it_state = cpu_ns.it_state;

fn readQ(cpu: *const Cpu, n: u3) u128 {
    var q: u128 = 0;
    var k: u5 = 4;
    while (k > 0) : (k -= 1) q = q << 32 | cpu.fp.bank.readS(@as(u5, n) * 4 + (k - 1));
    return q;
}

fn run(in: vectors.In) vectors.Out {
    var cpu: Cpu = .{ .bus = undefined };
    for (0..32) |i| cpu.fp.bank.writeS(@intCast(i), vectors.bankAt(@intCast(i)));
    cpu.fp.vpr = @bitCast(in.vpr);
    cpu.fp.fpscr.ltpsize = in.ltpsize;
    cpu.regs.xpsr = it_state.put(cpu.regs.xpsr, in.it);
    cpu.regs.set(14, in.lr);
    const instr: cpu_ns.instr.Instr = .{ .address = 0x100, .hw1 = in.hw1, .hw2 = in.hw2, .size = @intCast(in.size) };
    const exec = cpu_ns.ops.mve_vpred.group.decode(instr) orelse return vectors.none;
    exec(&cpu, instr) catch unreachable;
    return .{ .q = readQ(&cpu, @intCast(in.hw2 >> 13)), .vpr = @bitCast(cpu.fp.vpr), .it = it_state.get(cpu.regs.xpsr) };
}

test "mve_vpred matches the Arm ARM" {
    try vector.expectAll(vectors.In, vectors.Out, run, &vectors.all);
}

test "every vector is counted in covered and names the group" {
    try std.testing.expectEqual(vectors.all.len, vectors.covered.len);
    for (vectors.covered) |name| try std.testing.expectEqualStrings("mve_vpred", name);
}
