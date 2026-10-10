//! Covers src/chip/core/cpu/conformance/base/push_pop_vectors.zig: each vector
//! runs through the `push_pop` group on a core in Thread mode over the
//! exception tests' 1 KiB of RAM.
const std = @import("std");
const ra8 = @import("ra8");
const vector = ra8.chip.core.cpu.conformance_vector;
const vectors = ra8.chip.core.cpu.conformance_base.push_pop_vectors;
const cpu_ns = ra8.chip.core.cpu;
const fixture = @import("../../exception/ram.zig");

fn fault(err: cpu_ns.op.Error) vectors.Fault {
    return switch (err) {
        error.Unaligned => .unaligned,
        error.StackOverflow => .stack_overflow,
        else => .other,
    };
}

fn observe(cpu: *const cpu_ns.cpu.Cpu, ram: *fixture.Ram, ended: vectors.Fault) vectors.Out {
    var out: vectors.Out = .{ .fault = ended, .sp = cpu.regs.sp(), .lr = cpu.regs.lr, .pc = cpu.regs.pc };
    for (0..4) |i| out.below[i] = ram.word(vectors.window + 4 * @as(u32, @intCast(i)));
    for (0..8) |i| out.low[i] = cpu.regs.get(@intCast(i));
    out.thumb = cpu.regs.xpsr & cpu_ns.regs.xpsr_bits.thumb != 0;
    return out;
}

fn run(in: vectors.In) vectors.Out {
    var ram: fixture.Ram = .{};
    var cpu: cpu_ns.cpu.Cpu = .{ .bus = ram.view(), .regs = .{ .xpsr = cpu_ns.regs.xpsr_bits.thumb } };
    for (0..13) |n| cpu.regs.set(@intCast(n), vectors.reg_base + @as(u32, @intCast(n)));
    cpu.regs.lr = vectors.lr;
    cpu.regs.pc = 0x1004;
    cpu.regs.setSp(in.sp);
    cpu.regs.msplim = in.msplim;
    for (in.stack, 0..) |word, i| ram.putWord(in.sp + 4 * @as(u32, @intCast(i)), word);
    const instr: cpu_ns.instr.Instr = .{ .address = 0x1000, .hw1 = in.hw1, .size = @intCast(in.size) };
    const exec = cpu_ns.ops.push_pop.group.decode(instr) orelse return .{ .claimed = false };
    exec(&cpu, instr) catch |err| return observe(&cpu, &ram, fault(err));
    return observe(&cpu, &ram, .none);
}

test "push_pop matches the Arm ARM" {
    try vector.expectAll(vectors.In, vectors.Out, run, &vectors.all);
}

test "every vector is counted in covered and names the group" {
    try std.testing.expectEqual(vectors.all.len, vectors.covered.len);
    for (vectors.covered) |name| try std.testing.expectEqualStrings("push_pop", name);
}
