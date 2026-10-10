//! Covers src/chip/core/cpu/conformance/base/cps_vectors.zig: each vector runs
//! through the `cps` group on a bare register file.
const std = @import("std");
const ra8 = @import("ra8");
const vector = ra8.chip.core.cpu.conformance_vector;
const vectors = ra8.chip.core.cpu.conformance_base.cps_vectors;
const cpu_ns = ra8.chip.core.cpu;
const regs = cpu_ns.regs;
const cps = cpu_ns.ops.cps;

fn run(in: vectors.In) vectors.Out {
    var cpu: cpu_ns.cpu.Cpu = .{ .bus = undefined, .regs = .{ .xpsr = regs.xpsr_bits.thumb | in.ipsr } };
    cpu.regs.primask = in.primask;
    cpu.regs.faultmask = in.faultmask;
    if (in.npriv) cpu.regs.control |= regs.control_bits.npriv;
    const instr: cpu_ns.instr.Instr = .{ .address = 0x1000, .hw1 = in.hw1, .size = 2 };
    const exec = cps.group.decode(instr) orelse return .{ .claimed = false };
    exec(&cpu, instr) catch return .{ .claimed = false, .primask = 1, .faultmask = 1 };
    return .{ .primask = @intCast(cpu.regs.primask), .faultmask = @intCast(cpu.regs.faultmask) };
}

test "cps matches the Arm ARM" {
    try vector.expectAll(vectors.In, vectors.Out, run, &vectors.all);
}

test "every vector is counted in covered and names the group" {
    try std.testing.expectEqual(vectors.all.len, vectors.covered.len);
    for (vectors.covered) |name| try std.testing.expectEqualStrings("cps", name);
}
