//! Covers src/chip/core/cpu/conformance/base/bxns_vectors.zig: each vector runs
//! through the `bxns` group on a bare core with a Non-secure MSP banked.
const std = @import("std");
const ra8 = @import("ra8");
const vector = ra8.chip.core.cpu.conformance.vector;
const vectors = ra8.chip.core.cpu.conformance.base.bxns_vectors;
const cpu_ns = ra8.chip.core.cpu;

fn fault(err: cpu_ns.op.Error) vectors.Fault {
    return switch (err) {
        error.Undefined => .undefined,
        else => .other,
    };
}

fn observe(cpu: *const cpu_ns.cpu.Cpu, ended: vectors.Fault) vectors.Out {
    return .{
        .fault = ended,
        .pc = cpu.regs.pc,
        .sp = cpu.regs.sp(),
        .secure = cpu.banked.current == .secure,
    };
}

fn run(in: vectors.In) vectors.Out {
    var cpu: cpu_ns.cpu.Cpu = .{ .bus = undefined, .regs = .{ .xpsr = cpu_ns.regs.xpsr_bits.thumb } };
    cpu.regs.pc = vectors.start_pc;
    cpu.regs.setSp(vectors.secure_msp);
    cpu.banked.other.msp = vectors.ns_msp;
    if (!in.secure) cpu.banked.current = .non_secure;
    cpu.regs.set(@intCast((in.hw1 >> 3) & 0xF), in.target);
    const instr: cpu_ns.instr.Instr = .{ .address = 0x1000, .hw1 = in.hw1, .size = @intCast(in.size) };
    const exec = cpu_ns.ops.bxns.group.decode(instr) orelse return .{ .claimed = false, .pc = 0, .sp = 0, .secure = false };
    exec(&cpu, instr) catch |err| return observe(&cpu, fault(err));
    return observe(&cpu, .none);
}

test "bxns matches the Arm ARM" {
    try vector.expectAll(vectors.In, vectors.Out, run, &vectors.all);
}

test "every vector is counted in covered and names the group" {
    try std.testing.expectEqual(vectors.all.len, vectors.covered.len);
    for (vectors.covered) |name| try std.testing.expectEqualStrings("bxns", name);
}
