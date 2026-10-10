//! Covers src/chip/core/cpu/conformance/base/dp_shifted_vectors.zig: each vector
//! runs through the `dp_shifted` group on a bare core holding N and C.
const std = @import("std");
const ra8 = @import("ra8");
const vector = ra8.chip.core.cpu.conformance_vector;
const vectors = ra8.chip.core.cpu.conformance_base.dp_shifted_vectors;
const cpu_ns = ra8.chip.core.cpu;
const Cpu = cpu_ns.cpu.Cpu;
const nzcv: u32 = 0xF000_0000;

fn read(cpu: *Cpu, rd: u4) u32 {
    return switch (rd) {
        13 => cpu.regs.sp(),
        15 => 0,
        else => cpu.regs.get(rd),
    };
}

fn seed(cpu: *Cpu, in: vectors.In) void {
    const rn: u4 = @intCast(in.hw1 & 0xF);
    const rm: u4 = @intCast(in.hw2 & 0xF);
    if (rn == 13) cpu.regs.setSp(in.n) else if (rn != 15) cpu.regs.set(rn, in.n);
    if (rm != 13 and rm != 15) cpu.regs.set(rm, in.m);
}

fn run(in: vectors.In) vectors.Out {
    const xpsr = cpu_ns.regs.xpsr_bits.thumb | vectors.flags;
    var cpu: Cpu = .{ .bus = undefined, .regs = .{ .xpsr = xpsr } };
    seed(&cpu, in);
    const instr: cpu_ns.instr.Instr = .{ .address = 0x1000, .hw1 = in.hw1, .hw2 = in.hw2, .size = @intCast(in.size) };
    const exec = cpu_ns.ops.dp_shifted.group.decode(instr) orelse return .{ .claimed = false, .flags = 0 };
    exec(&cpu, instr) catch return .{ .claimed = false, .rd = 1, .flags = 0 };
    return .{ .rd = read(&cpu, @intCast((in.hw2 >> 8) & 0xF)), .flags = cpu.regs.xpsr & nzcv };
}

test "dp_shifted matches the Arm ARM" {
    try vector.expectAll(vectors.In, vectors.Out, run, &vectors.all);
}

test "every vector is counted in covered and names the group" {
    try std.testing.expectEqual(vectors.all.len, vectors.covered.len);
    for (vectors.covered) |name| try std.testing.expectEqualStrings("dp_shifted", name);
}
