//! Covers src/chip/core/cpu/conformance/base/fp_system_vectors.zig: each vector
//! runs through the `fp_system` group with its operands, FPSCR, VPR, R1,
//! xPSR, security state and CONTROL.SFPA.
const std = @import("std");
const ra8 = @import("ra8");
const vector = ra8.chip.core.cpu.conformance.vector;
const vectors = ra8.chip.core.cpu.conformance.base.fp_system_vectors;
const cpu_ns = ra8.chip.core.cpu;
const Cpu = cpu_ns.cpu.Cpu;
const Fpscr = ra8.chip.core.cpu.fpu.fpscr.Fpscr;
const sfpa = cpu_ns.regs.control_bits.sfpa;

fn load(cpu: *Cpu, in: vectors.In) void {
    if (in.double) {
        cpu.fp.bank.writeD(0, in.a);
        cpu.fp.bank.writeD(1, in.b);
    } else {
        cpu.fp.bank.writeS(0, @truncate(in.a));
        cpu.fp.bank.writeS(1, @truncate(in.b));
    }
    cpu.fp.fpscr = @bitCast(in.fpscr);
    cpu.fp.vpr = @bitCast(in.vpr);
    cpu.regs.set(1, in.r1);
    cpu.regs.xpsr = in.xpsr;
    if (!in.secure) cpu.banked.current = .non_secure;
    if (in.sfpa) cpu.regs.control |= sfpa;
}

fn run(in: vectors.In) vectors.Out {
    var cpu: Cpu = .{ .bus = undefined };
    load(&cpu, in);
    const instr: cpu_ns.instr.Instr = .{ .address = 0, .hw1 = in.hw1, .hw2 = in.hw2, .size = @intCast(in.size) };
    const exec = cpu_ns.ops.fp_system.group.decode(instr) orelse return vectors.none;
    const ended: vectors.Fault = if (exec(&cpu, instr)) .none else |err| if (err == error.Undefined) .undefined_instr else .other;
    return .{
        .fault = ended,
        .fpscr = @as(Fpscr, cpu.fp.fpscr).bits(),
        .r1 = cpu.regs.get(1),
        .xpsr = cpu.regs.xpsr,
        .vpr = @bitCast(cpu.fp.vpr),
        .sfpa = cpu.regs.control & sfpa != 0,
    };
}

test "fp_system matches the Arm ARM" {
    try vector.expectAll(vectors.In, vectors.Out, run, &vectors.all);
}

test "every vector is counted in covered and names the group" {
    try std.testing.expectEqual(vectors.all.len, vectors.covered.len);
    for (vectors.covered) |name| try std.testing.expectEqualStrings("fp_system", name);
}
