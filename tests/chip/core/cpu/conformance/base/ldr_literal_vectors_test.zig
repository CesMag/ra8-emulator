//! Covers src/chip/core/cpu/conformance/base/ldr_literal_vectors.zig: each vector
//! runs through the `ldr_literal` group over the exception tests' 1 KiB of
//! RAM at 0x2000_0000.
const std = @import("std");
const ra8 = @import("ra8");
const vector = ra8.chip.core.cpu.conformance.vector;
const vectors = ra8.chip.core.cpu.conformance.base.ldr_literal_vectors;
const cpu_ns = ra8.chip.core.cpu;
const fixture = @import("../../exception/ram.zig");

fn observe(cpu: *const cpu_ns.cpu.Cpu, rt: u3, ended: vectors.Fault) vectors.Out {
    var kept = true;
    for (0..8) |n| {
        if (n != rt and cpu.regs.get(@intCast(n)) != vectors.fill) kept = false;
    }
    return .{ .fault = ended, .rt = cpu.regs.get(rt), .others_kept = kept };
}

fn run(in: vectors.In) vectors.Out {
    var ram: fixture.Ram = .{};
    var cpu: cpu_ns.cpu.Cpu = .{ .bus = ram.view(), .regs = .{ .xpsr = cpu_ns.regs.xpsr_bits.thumb } };
    for (0..8) |n| cpu.regs.set(@intCast(n), vectors.fill);
    if (in.at != 0) ram.putWord(in.at, vectors.literal);
    const instr: cpu_ns.instr.Instr = .{ .address = in.address, .hw1 = in.hw1, .size = @intCast(in.size) };
    const exec = cpu_ns.ops.ldr_literal.group.decode(instr) orelse return .{ .claimed = false, .rt = 0, .others_kept = false };
    exec(&cpu, instr) catch |err| return observe(&cpu, in.rt, if (err == error.Unmapped) .unmapped else .other);
    return observe(&cpu, in.rt, .none);
}

test "ldr_literal matches the Arm ARM" {
    try vector.expectAll(vectors.In, vectors.Out, run, &vectors.all);
}

test "every vector is counted in covered and names the group" {
    try std.testing.expectEqual(vectors.all.len, vectors.covered.len);
    for (vectors.covered) |name| try std.testing.expectEqualStrings("ldr_literal", name);
}
