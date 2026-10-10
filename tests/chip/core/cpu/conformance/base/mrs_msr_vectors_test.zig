//! Covers src/chip/core/cpu/conformance/base/mrs_msr_vectors.zig: each vector
//! runs through the `mrs_msr` group on a bare Secure core seeded with the
//! vector file's special-register values.
const std = @import("std");
const ra8 = @import("ra8");
const vector = ra8.chip.core.cpu.conformance_vector;
const vectors = ra8.chip.core.cpu.conformance_base.mrs_msr_vectors;
const cpu_ns = ra8.chip.core.cpu;
const Cpu = cpu_ns.cpu.Cpu;
const seed = vectors.seed;
const apsr_bits: u32 = 0xF80F_0000;

fn start(in: vectors.In) Cpu {
    var cpu: Cpu = .{ .bus = undefined, .regs = .{
        .xpsr = cpu_ns.regs.xpsr_bits.thumb | seed.apsr | in.ipsr,
        .control = @intFromBool(in.npriv),
        .msp = seed.msp,
        .psp = seed.psp,
        .msplim = seed.msplim,
        .psplim = seed.psplim,
        .primask = seed.primask,
        .basepri = seed.basepri,
    } };
    cpu.banked.other.msp = seed.ns_msp;
    cpu.regs.set(0, seed.r0);
    cpu.regs.set(1, in.rs);
    return cpu;
}

fn run(in: vectors.In) vectors.Out {
    var cpu = start(in);
    const instr: cpu_ns.instr.Instr = .{ .address = 0x1000, .hw1 = in.hw1, .hw2 = in.hw2, .size = @intCast(in.size) };
    const exec = cpu_ns.ops.mrs_msr.group.decode(instr) orelse return vectors.Out{ .claimed = false, .r0 = 0, .apsr = 0, .primask = 0, .basepri = 0, .msp = 0, .psp = 0, .msplim = 0, .ns_msp = 0 };
    exec(&cpu, instr) catch return .{ .claimed = false };
    const r = &cpu.regs;
    return .{
        .r0 = r.get(0),
        .r12 = r.get(12),
        .apsr = r.xpsr & apsr_bits,
        .primask = r.primask,
        .basepri = r.basepri,
        .faultmask = r.faultmask,
        .control = r.control,
        .msp = r.msp,
        .psp = r.psp,
        .msplim = r.msplim,
        .ns_msp = cpu.banked.other.msp,
    };
}

test "mrs_msr matches the Arm ARM" {
    try vector.expectAll(vectors.In, vectors.Out, run, &vectors.all);
}

test "every vector is counted in covered and names the group" {
    try std.testing.expectEqual(vectors.all.len, vectors.covered.len);
    for (vectors.covered) |name| try std.testing.expectEqualStrings("mrs_msr", name);
}
