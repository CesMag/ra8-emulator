//! Covers src/chip/core/cpu/conformance/base/ldst/wide_vectors.zig: each vector
//! runs through the `ldst_wide` group over the exception tests' 1 KiB of
//! RAM at 0x2000_0000, with CCR.UNALIGN_TRP clear.
const std = @import("std");
const ra8 = @import("ra8");
const vector = ra8.chip.core.cpu.conformance.vector;
const vectors = ra8.chip.core.cpu.conformance.base.ldst.wide_vectors;
const cpu_ns = ra8.chip.core.cpu;
const Cpu = cpu_ns.cpu.Cpu;
const fixture = @import("../../../exception/ram.zig");

fn observe(cpu: *const Cpu, ram: *fixture.Ram, in: vectors.In, ended: vectors.Fault) vectors.Out {
    const rt: u4 = @intCast(in.hw2 >> 12);
    const value = switch (rt) {
        13 => cpu.regs.sp(),
        15 => cpu.regs.pc,
        else => cpu.regs.get(rt),
    };
    const mem = if (in.probe != 0) ram.word(in.probe) else 0;
    return .{ .fault = ended, .rt = value, .rn = cpu.regs.get(0), .mem = mem };
}

fn run(in: vectors.In) vectors.Out {
    var ram: fixture.Ram = .{};
    var cpu: Cpu = .{ .bus = ram.view(), .regs = .{ .xpsr = cpu_ns.regs.xpsr_bits.thumb } };
    for (0..15) |n| cpu.regs.set(@intCast(n), vectors.fill);
    cpu.regs.pc = vectors.fill;
    cpu.regs.set(0, vectors.base);
    cpu.regs.set(1, vectors.src);
    if (in.at != 0) ram.putWord(in.at, in.lit);
    const instr: cpu_ns.instr.Instr = .{ .address = 0x2000_0100, .hw1 = in.hw1, .hw2 = in.hw2, .size = @intCast(in.size) };
    const exec = cpu_ns.ops.ldst.wide.group.decode(instr) orelse return .{ .claimed = false, .rt = 0, .rn = 0 };
    exec(&cpu, instr) catch |err| return observe(&cpu, &ram, in, if (err == error.Unmapped) .unmapped else .other);
    return observe(&cpu, &ram, in, .none);
}

test "ldst_wide matches the Arm ARM" {
    try vector.expectAll(vectors.In, vectors.Out, run, &vectors.all);
}

test "every vector is counted in covered and names the group" {
    try std.testing.expectEqual(vectors.all.len, vectors.covered.len);
    for (vectors.covered) |name| try std.testing.expectEqualStrings("ldst_wide", name);
}
