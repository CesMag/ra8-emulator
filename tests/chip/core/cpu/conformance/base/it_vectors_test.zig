//! Covers src/chip/core/cpu/conformance/base/it_vectors.zig: each vector runs
//! through the `it` group on a bare register file.
const std = @import("std");
const ra8 = @import("ra8");
const vector = ra8.chip.core.cpu.conformance_vector;
const vectors = ra8.chip.core.cpu.conformance_base.it_vectors;
const cpu_ns = ra8.chip.core.cpu;
const it = cpu_ns.ops.it;
const it_state = cpu_ns.it_state;

fn run(in: vectors.In) vectors.Out {
    var cpu: cpu_ns.cpu.Cpu = .{ .bus = undefined, .regs = .{ .xpsr = cpu_ns.regs.xpsr_bits.thumb } };
    cpu.regs.xpsr = it_state.put(cpu.regs.xpsr, in.it);
    const instr: cpu_ns.instr.Instr = .{ .address = 0x1000, .hw1 = in.hw1, .size = 2 };
    const exec = it.group.decode(instr) orelse return .{ .claimed = false };
    exec(&cpu, instr) catch |err| return .{
        .undefined = err == error.Undefined,
        .it = it_state.get(cpu.regs.xpsr),
    };
    return .{ .it = it_state.get(cpu.regs.xpsr) };
}

test "it matches the Arm ARM" {
    try vector.expectAll(vectors.In, vectors.Out, run, &vectors.all);
}

test "every vector is counted in covered and names the group" {
    try std.testing.expectEqual(vectors.all.len, vectors.covered.len);
    for (vectors.covered) |name| try std.testing.expectEqualStrings("it", name);
}
