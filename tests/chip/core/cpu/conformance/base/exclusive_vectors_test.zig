//! Covers src/chip/core/cpu/conformance/base/exclusive_vectors.zig: each vector
//! runs through the `exclusive` group over the exception tests' 1 KiB of RAM
//! at 0x2000_0000, with the local monitor set from the vector.
const std = @import("std");
const ra8 = @import("ra8");
const vector = ra8.chip.core.cpu.conformance_vector;
const vectors = ra8.chip.core.cpu.conformance_base.exclusive_vectors;
const cpu_ns = ra8.chip.core.cpu;
const Cpu = cpu_ns.cpu.Cpu;
const fixture = @import("../../exception/ram.zig");

fn observe(cpu: *const Cpu, ram: *fixture.Ram, in: vectors.In, ended: vectors.Fault) vectors.Out {
    return .{
        .fault = ended,
        .rt = cpu.regs.get(1),
        .rd = cpu.regs.get(2),
        .tag = cpu.exclusive orelse 0,
        .mem = ram.word(in.probe),
    };
}

fn faultOf(err: anyerror) vectors.Fault {
    return switch (err) {
        error.Unmapped => .unmapped,
        error.Unaligned => .unaligned,
        else => .other,
    };
}

fn run(in: vectors.In) vectors.Out {
    var ram: fixture.Ram = .{};
    var cpu: Cpu = .{ .bus = ram.view(), .regs = .{ .xpsr = cpu_ns.regs.xpsr_bits.thumb } };
    cpu.regs.set(0, in.rn);
    cpu.regs.set(1, vectors.src);
    cpu.regs.set(2, vectors.fill);
    cpu.exclusive = if (in.tag != 0) in.tag else null;
    ram.putWord(vectors.base, vectors.literal);
    ram.putWord(vectors.base + 4, vectors.next);
    const instr: cpu_ns.instr.Instr = .{ .address = 0x2000_0100, .hw1 = in.hw1, .hw2 = in.hw2, .size = @intCast(in.size) };
    const exec = cpu_ns.ops.exclusive.group.decode(instr) orelse return .{ .claimed = false, .rt = 0, .rd = 0, .mem = 0 };
    exec(&cpu, instr) catch |err| return observe(&cpu, &ram, in, faultOf(err));
    return observe(&cpu, &ram, in, .none);
}

test "exclusive matches the Arm ARM" {
    try vector.expectAll(vectors.In, vectors.Out, run, &vectors.all);
}

test "every vector is counted in covered and names the group" {
    try std.testing.expectEqual(vectors.all.len, vectors.covered.len);
    for (vectors.covered) |name| try std.testing.expectEqualStrings("exclusive", name);
}
