//! Covers src/chip/core/cpu/conformance/base/vscclrm_vectors.zig: each vector
//! runs through the `vscclrm` group on a core whose S registers all start
//! non-zero and whose VPR starts at 0x00AB_1234.
const std = @import("std");
const ra8 = @import("ra8");
const vector = ra8.chip.core.cpu.conformance_vector;
const vectors = ra8.chip.core.cpu.conformance_base.vscclrm_vectors;
const cpu_ns = ra8.chip.core.cpu;
const Cpu = cpu_ns.cpu.Cpu;

fn run(in: vectors.In) vectors.Out {
    var cpu: Cpu = .{ .bus = undefined };
    cpu.fp.cpacr = ra8.chip.core.cpu.fpu.cpacr.full_access;
    for (0..32) |i| cpu.fp.bank.writeS(@intCast(i), 0x5A00_0000 | @as(u32, @intCast(i)) * 0x0101 + 1);
    cpu.fp.vpr = @bitCast(vectors.vpr_reset);
    cpu.fp.context.fpccr.aspen = in.aspen;
    cpu.regs.control = in.control;
    if (!in.secure) cpu.banked.current = .non_secure;
    const instr: cpu_ns.instr.Instr = .{ .address = 0x100, .hw1 = in.hw1, .hw2 = in.hw2, .size = @intCast(in.size) };
    const exec = cpu_ns.ops.vscclrm.group.decode(instr) orelse return vectors.none;
    const fault: vectors.Fault = if (exec(&cpu, instr)) .none else |err| switch (err) {
        error.Undefined => .undefined_instr,
        else => unreachable,
    };
    var cleared: u32 = 0;
    for (0..32) |i| {
        if (cpu.fp.bank.readS(@intCast(i)) == 0) cleared |= @as(u32, 1) << @intCast(i);
    }
    return .{ .fault = fault, .cleared = cleared, .vpr = @bitCast(cpu.fp.vpr), .control = cpu.regs.control };
}

test "vscclrm matches the Arm ARM" {
    try vector.expectAll(vectors.In, vectors.Out, run, &vectors.all);
}

test "every vector is counted in covered and names the group" {
    try std.testing.expectEqual(vectors.all.len, vectors.covered.len);
    for (vectors.covered) |name| try std.testing.expectEqualStrings("vscclrm", name);
}
