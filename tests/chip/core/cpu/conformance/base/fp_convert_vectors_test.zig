//! Covers src/chip/core/cpu/conformance/base/fp_convert_vectors.zig: each vector
//! presets the destination to all ones, writes its source, and runs the
//! `fp_convert` group.
const std = @import("std");
const ra8 = @import("ra8");
const vector = ra8.chip.core.cpu.conformance_vector;
const vectors = ra8.chip.core.cpu.conformance_base.fp_convert_vectors;
const cpu_ns = ra8.chip.core.cpu;
const Cpu = cpu_ns.cpu.Cpu;
const Fpscr = ra8.chip.core.cpu.fpu.fpscr.Fpscr;

fn put(cpu: *Cpu, wide: bool, reg: u5, value: u64) void {
    if (wide) cpu.fp.bank.writeD(@intCast(reg), value) else cpu.fp.bank.writeS(reg, @truncate(value));
}

fn run(in: vectors.In) vectors.Out {
    var cpu: Cpu = .{ .bus = undefined };
    cpu.fp.fpscr = @bitCast(in.fpscr);
    put(&cpu, in.dst_wide, in.dst_reg, vectors.dst_reset);
    put(&cpu, in.src_wide, in.src_reg, in.src);
    const instr: cpu_ns.instr.Instr = .{ .address = 0, .hw1 = in.hw1, .hw2 = in.hw2, .size = @intCast(in.size) };
    const exec = cpu_ns.ops.fp_convert.group.decode(instr) orelse return vectors.none;
    exec(&cpu, instr) catch return vectors.none;
    const dst: u64 = if (in.dst_wide) cpu.fp.bank.readD(@intCast(in.dst_reg)) else cpu.fp.bank.readS(in.dst_reg);
    return .{ .dst = dst, .fpscr = @as(Fpscr, cpu.fp.fpscr).bits() };
}

test "fp_convert matches the Arm ARM" {
    try vector.expectAll(vectors.In, vectors.Out, run, &vectors.all);
}

test "every vector is counted in covered and names the group" {
    try std.testing.expectEqual(vectors.all.len, vectors.covered.len);
    for (vectors.covered) |name| try std.testing.expectEqualStrings("fp_convert", name);
}
