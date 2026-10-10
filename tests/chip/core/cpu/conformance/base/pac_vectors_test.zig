//! Covers src/chip/core/cpu/conformance/base/pac_vectors.zig: each vector runs
//! through the `pac` group on an Armv8.1-M core with both PAC keys loaded
//! and EPSR.B set.
const std = @import("std");
const ra8 = @import("ra8");
const vector = ra8.chip.core.cpu.conformance.vector;
const vectors = ra8.chip.core.cpu.conformance.base.pac_vectors;
const cpu_ns = ra8.chip.core.cpu;
const Cpu = cpu_ns.cpu.Cpu;
const xpsr_bits = cpu_ns.regs.xpsr_bits;
const fixture = @import("../../exception/ram.zig");

const bti: u32 = 1 << 21;

fn observe(cpu: *const Cpu, ended: vectors.Fault) vectors.Out {
    return .{
        .fault = ended,
        .r0 = cpu.regs.get(0),
        .r12 = cpu.regs.get(12),
        .pc = cpu.regs.pc,
        .thumb = cpu.regs.xpsr & xpsr_bits.thumb != 0,
        .bti = cpu.regs.xpsr & bti != 0,
    };
}

fn setUp(cpu: *Cpu, in: vectors.In) void {
    cpu.regs.pac_key_p = vectors.key_p;
    cpu.regs.pac_key_u = vectors.key_u;
    cpu.regs.setSp(vectors.sp_in);
    cpu.regs.control = in.control;
    cpu.regs.set(0, in.r0);
    cpu.regs.set(1, vectors.r1_in);
    cpu.regs.set(2, vectors.r2_in);
    cpu.regs.set(3, vectors.r3_in);
    cpu.regs.set(12, in.r12);
    cpu.regs.set(14, vectors.lr_in);
    cpu.regs.pc = vectors.pc_in;
}

fn run(in: vectors.In) vectors.Out {
    var ram: fixture.Ram = .{};
    var cpu: Cpu = .{ .bus = ram.view(), .regs = .{ .xpsr = xpsr_bits.thumb | bti } };
    setUp(&cpu, in);
    const instr: cpu_ns.instr.Instr = .{ .address = vectors.pc_in, .hw1 = in.hw1, .hw2 = in.hw2, .size = @intCast(in.size) };
    const exec = cpu_ns.ops.pac.group.decode(instr) orelse return vectors.none;
    exec(&cpu, instr) catch |err| return observe(&cpu, if (err == error.InvalidState) .invalid_state else .other);
    return observe(&cpu, .none);
}

test "pac matches the Arm ARM" {
    try vector.expectAll(vectors.In, vectors.Out, run, &vectors.all);
}

test "every vector is counted in covered and names the group" {
    try std.testing.expectEqual(vectors.all.len, vectors.covered.len);
    for (vectors.covered) |name| try std.testing.expectEqualStrings("pac", name);
}
