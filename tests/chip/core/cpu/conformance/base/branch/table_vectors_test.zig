//! Covers src/chip/core/cpu/conformance/base/branch/table_vectors.zig: each
//! vector runs through the `table_branch` group over the exception tests'
//! 1 KiB of RAM at 0x2000_0000.
const std = @import("std");
const ra8 = @import("ra8");
const vector = ra8.chip.core.cpu.conformance.vector;
const vectors = ra8.chip.core.cpu.conformance.base.table_branch_vectors;
const cpu_ns = ra8.chip.core.cpu;
const fixture = @import("../../../exception/ram.zig");

fn run(in: vectors.In) vectors.Out {
    var ram: fixture.Ram = .{};
    var cpu: cpu_ns.cpu.Cpu = .{ .bus = ram.view(), .regs = .{ .xpsr = cpu_ns.regs.xpsr_bits.thumb } };
    const rn: u4 = @intCast(in.hw1 & 0xF);
    const rm: u4 = @intCast(in.hw2 & 0xF);
    if (rn != 13 and rn != 15) cpu.regs.set(rn, in.base);
    if (rm != 13 and rm != 15) cpu.regs.set(rm, in.index);
    if (in.at != 0) ram.putWord(in.at, in.word);
    const instr: cpu_ns.instr.Instr = .{ .address = in.address, .hw1 = in.hw1, .hw2 = in.hw2, .size = @intCast(in.size) };
    const exec = cpu_ns.ops.table_branch.group.decode(instr) orelse return .{ .claimed = false };
    exec(&cpu, instr) catch |err| return .{ .fault = if (err == error.Unmapped) .unmapped else .other, .pc = cpu.regs.pc };
    return .{ .pc = cpu.regs.pc };
}

test "table_branch matches the Arm ARM" {
    try vector.expectAll(vectors.In, vectors.Out, run, &vectors.all);
}

test "every vector is counted in covered and names the group" {
    try std.testing.expectEqual(vectors.all.len, vectors.covered.len);
    for (vectors.covered) |name| try std.testing.expectEqualStrings("table_branch", name);
}
