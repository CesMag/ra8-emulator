//! Covers src/chip/core/cpu/conformance/base/preload_vectors.zig: each vector
//! runs through the `preload` group over the exception tests' 1 KiB of RAM,
//! with Rn pointing outside it so any access would fault.
const std = @import("std");
const ra8 = @import("ra8");
const vector = ra8.chip.core.cpu.conformance.vector;
const vectors = ra8.chip.core.cpu.conformance.base.preload_vectors;
const cpu_ns = ra8.chip.core.cpu;
const fixture = @import("../../exception/ram.zig");
const nzcvq: u32 = 0xF800_0000;

fn run(in: vectors.In) vectors.Out {
    var ram: fixture.Ram = .{};
    var cpu: cpu_ns.cpu.Cpu = .{ .bus = ram.view(), .regs = .{ .xpsr = cpu_ns.regs.xpsr_bits.thumb | vectors.flags } };
    cpu.regs.set(0, vectors.base);
    cpu.regs.set(1, vectors.index);
    cpu.regs.set(12, vectors.base);
    const instr: cpu_ns.instr.Instr = .{ .address = 0x1000, .hw1 = in.hw1, .hw2 = in.hw2, .size = @intCast(in.size) };
    const exec = cpu_ns.ops.preload.group.decode(instr) orelse return .{ .claimed = false, .r0 = 0, .r1 = 0, .flags = 0 };
    exec(&cpu, instr) catch return .{ .claimed = false, .r0 = 1, .r1 = 0, .flags = 0 };
    return .{ .r0 = cpu.regs.get(0), .r1 = cpu.regs.get(1), .flags = cpu.regs.xpsr & nzcvq };
}

test "preload matches the Arm ARM" {
    try vector.expectAll(vectors.In, vectors.Out, run, &vectors.all);
}

test "every vector is counted in covered and names the group" {
    try std.testing.expectEqual(vectors.all.len, vectors.covered.len);
    for (vectors.covered) |name| try std.testing.expectEqualStrings("preload", name);
}
