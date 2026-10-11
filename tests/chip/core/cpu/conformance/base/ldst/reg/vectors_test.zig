//! Covers src/chip/core/cpu/conformance/base/ldst_reg_vectors.zig: each vector
//! runs through the `ldst_reg` group over the exception tests' 1 KiB of
//! RAM, whose System Control Space page leaves CCR.UNALIGN_TRP clear.
const std = @import("std");
const ra8 = @import("ra8");
const vector = ra8.chip.core.cpu.conformance.vector;
const vectors = ra8.chip.core.cpu.conformance.base.ldst.reg.vectors;
const cpu_ns = ra8.chip.core.cpu;
const fixture = @import("../../../../exception/ram.zig");

fn observe(cpu: *const cpu_ns.cpu.Cpu, ram: *fixture.Ram, rt: u3, ended: vectors.Fault) vectors.Out {
    return .{
        .fault = ended,
        .rt = cpu.regs.get(rt),
        .mem = .{ ram.word(vectors.window), ram.word(vectors.window + 4) },
    };
}

fn run(in: vectors.In) vectors.Out {
    var ram: fixture.Ram = .{};
    var cpu: cpu_ns.cpu.Cpu = .{ .bus = ram.view(), .regs = .{ .xpsr = cpu_ns.regs.xpsr_bits.thumb } };
    cpu.regs.set(in.rt, in.value);
    cpu.regs.set(1, in.base);
    cpu.regs.set(2, in.offset);
    ram.putWord(vectors.window, in.mem[0]);
    ram.putWord(vectors.window + 4, in.mem[1]);
    const instr: cpu_ns.instr.Instr = .{ .address = 0x1000, .hw1 = in.hw1, .size = @intCast(in.size) };
    const exec = cpu_ns.ops.ldst.reg.group.decode(instr) orelse return .{ .claimed = false, .rt = 0, .mem = .{ 0, 0 } };
    exec(&cpu, instr) catch |err| return observe(&cpu, &ram, in.rt, if (err == error.Unmapped) .unmapped else .other);
    return observe(&cpu, &ram, in.rt, .none);
}

test "ldst_reg matches the Arm ARM" {
    try vector.expectAll(vectors.In, vectors.Out, run, &vectors.all);
}

test "every vector is counted in covered and names the group" {
    try std.testing.expectEqual(vectors.all.len, vectors.covered.len);
    for (vectors.covered) |name| try std.testing.expectEqualStrings("ldst_reg", name);
}
