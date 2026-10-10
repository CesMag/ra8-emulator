//! Covers src/chip/core/cpu/conformance/base/ldrd_strd_vectors.zig: each vector
//! runs through the `ldrd_strd` group over the exception tests' 1 KiB of
//! RAM at 0x2000_0000.
const std = @import("std");
const ra8 = @import("ra8");
const vector = ra8.chip.core.cpu.conformance_vector;
const vectors = ra8.chip.core.cpu.conformance_base.ldrd_strd_vectors;
const cpu_ns = ra8.chip.core.cpu;
const Cpu = cpu_ns.cpu.Cpu;
const fixture = @import("../../exception/ram.zig");

fn observe(cpu: *const Cpu, ram: *fixture.Ram, in: vectors.In, ended: vectors.Fault) vectors.Out {
    return .{
        .fault = ended,
        .r2 = cpu.regs.get(2),
        .r3 = cpu.regs.get(3),
        .rn = cpu.regs.get(0),
        .mem_lo = if (in.probe != 0) ram.word(in.probe) else 0,
        .mem_hi = if (in.probe != 0) ram.word(in.probe + 4) else 0,
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
    cpu.regs.set(2, vectors.src_lo);
    cpu.regs.set(3, vectors.src_hi);
    if (in.at != 0) {
        ram.putWord(in.at, vectors.lo);
        ram.putWord(in.at + 4, vectors.hi);
    }
    const instr: cpu_ns.instr.Instr = .{ .address = 0x2000_0100, .hw1 = in.hw1, .hw2 = in.hw2, .size = @intCast(in.size) };
    const exec = cpu_ns.ops.ldrd_strd.group.decode(instr) orelse return .{ .claimed = false, .r2 = 0, .r3 = 0, .rn = 0 };
    exec(&cpu, instr) catch |err| return observe(&cpu, &ram, in, faultOf(err));
    return observe(&cpu, &ram, in, .none);
}

test "ldrd_strd matches the Arm ARM" {
    try vector.expectAll(vectors.In, vectors.Out, run, &vectors.all);
}

test "every vector is counted in covered and names the group" {
    try std.testing.expectEqual(vectors.all.len, vectors.covered.len);
    for (vectors.covered) |name| try std.testing.expectEqualStrings("ldrd_strd", name);
}
