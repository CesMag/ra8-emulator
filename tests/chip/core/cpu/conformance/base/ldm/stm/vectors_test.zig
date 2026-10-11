//! Covers src/chip/core/cpu/conformance/base/ldm/stm/vectors.zig: each vector
//! runs through the `ldm_stm` group over the exception tests' 1 KiB of RAM.
const std = @import("std");
const ra8 = @import("ra8");
const vector = ra8.chip.core.cpu.conformance.vector;
const vectors = ra8.chip.core.cpu.conformance.base.ldm.stm.vectors;
const cpu_ns = ra8.chip.core.cpu;
const fixture = @import("../../../../exception/ram.zig");

fn fault(err: cpu_ns.op.Error) vectors.Fault {
    return switch (err) {
        error.Unaligned => .unaligned,
        error.Unmapped => .unmapped,
        else => .other,
    };
}

fn observe(cpu: *const cpu_ns.cpu.Cpu, ram: *fixture.Ram, ended: vectors.Fault) vectors.Out {
    var out: vectors.Out = .{ .fault = ended, .low = undefined };
    for (0..8) |i| out.low[i] = cpu.regs.get(@intCast(i));
    for (0..4) |i| out.mem[i] = ram.word(vectors.window + 4 * @as(u32, @intCast(i)));
    return out;
}

fn run(in: vectors.In) vectors.Out {
    var ram: fixture.Ram = .{};
    var cpu: cpu_ns.cpu.Cpu = .{ .bus = ram.view(), .regs = .{ .xpsr = cpu_ns.regs.xpsr_bits.thumb } };
    for (0..8) |n| cpu.regs.set(@intCast(n), vectors.reg_base + @as(u32, @intCast(n)));
    cpu.regs.set(@intCast((in.hw1 >> 8) & 7), in.base);
    for (vectors.initial, 0..) |word, i| ram.putWord(vectors.window + 4 * @as(u32, @intCast(i)), word);
    const instr: cpu_ns.instr.Instr = .{ .address = 0x1000, .hw1 = in.hw1, .size = @intCast(in.size) };
    const exec = cpu_ns.ops.ldm.stm.group.decode(instr) orelse return .{ .claimed = false, .low = .{ 0, 0, 0, 0, 0, 0, 0, 0 }, .mem = .{ 0, 0, 0, 0 } };
    exec(&cpu, instr) catch |err| return observe(&cpu, &ram, fault(err));
    return observe(&cpu, &ram, .none);
}

test "ldm_stm matches the Arm ARM" {
    try vector.expectAll(vectors.In, vectors.Out, run, &vectors.all);
}

test "every vector is counted in covered and names the group" {
    try std.testing.expectEqual(vectors.all.len, vectors.covered.len);
    for (vectors.covered) |name| try std.testing.expectEqualStrings("ldm_stm", name);
}
