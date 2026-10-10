//! Covers src/chip/core/cpu/conformance/base/long_shift_vectors.zig: each vector
//! runs through the `long_shift` group on a bare core holding N and C.
const std = @import("std");
const ra8 = @import("ra8");
const vector = ra8.chip.core.cpu.conformance_vector;
const vectors = ra8.chip.core.cpu.conformance_base.long_shift_vectors;
const cpu_ns = ra8.chip.core.cpu;
const Cpu = cpu_ns.cpu.Cpu;
const nzcv: u32 = 0xF000_0000;

fn put(cpu: *Cpu, r: u4, value: u32) void {
    if (r != 13 and r != 15) cpu.regs.set(r, value);
}

fn get(cpu: *const Cpu, r: u4) u32 {
    return if (r == 13 or r == 15) 0 else cpu.regs.get(r);
}

fn run(in: vectors.In) vectors.Out {
    var cpu: Cpu = .{ .bus = undefined, .regs = .{ .xpsr = cpu_ns.regs.xpsr_bits.thumb | vectors.flags } };
    const lo: u4 = @intCast(in.hw1 & 0xE);
    const hi: u4 = @intCast((in.hw2 >> 8) & 0xF);
    put(&cpu, lo, in.lo);
    put(&cpu, hi, in.hi);
    const instr: cpu_ns.instr.Instr = .{ .address = 0x1000, .hw1 = in.hw1, .hw2 = in.hw2, .size = @intCast(in.size) };
    const exec = cpu_ns.ops.long_shift.group.decode(instr) orelse return .{ .claimed = false, .flags = 0 };
    exec(&cpu, instr) catch return .{ .claimed = false, .lo = 1, .flags = 0 };
    return .{ .lo = get(&cpu, lo), .hi = get(&cpu, hi), .flags = cpu.regs.xpsr & nzcv };
}

test "long_shift matches the Arm ARM" {
    try vector.expectAll(vectors.In, vectors.Out, run, &vectors.all);
}

test "every vector is counted in covered and names the group" {
    try std.testing.expectEqual(vectors.all.len, vectors.covered.len);
    for (vectors.covered) |name| try std.testing.expectEqualStrings("long_shift", name);
}
