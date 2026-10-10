//! Covers src/chip/core/cpu/conformance/base/acq_rel_vectors.zig: each vector
//! runs through the `acq_rel` group over the exception tests' 1 KiB of RAM
//! at 0x2000_0000.
const std = @import("std");
const ra8 = @import("ra8");
const vector = ra8.chip.core.cpu.conformance_vector;
const vectors = ra8.chip.core.cpu.conformance_base.acq_rel_vectors;
const cpu_ns = ra8.chip.core.cpu;
const Cpu = cpu_ns.cpu.Cpu;
const fixture = @import("../../exception/ram.zig");

fn observe(cpu: *const Cpu, ram: *fixture.Ram, ended: vectors.Fault) vectors.Out {
    return .{ .fault = ended, .rt = cpu.regs.get(1), .rn = cpu.regs.get(0), .mem = ram.word(vectors.base) };
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
    ram.putWord(vectors.base, vectors.literal);
    ram.putWord(vectors.base + 4, vectors.next);
    const instr: cpu_ns.instr.Instr = .{ .address = 0x2000_0100, .hw1 = in.hw1, .hw2 = in.hw2, .size = @intCast(in.size) };
    const exec = cpu_ns.ops.acq_rel.group.decode(instr) orelse return .{ .claimed = false, .rt = 0, .rn = 0, .mem = 0 };
    exec(&cpu, instr) catch |err| return observe(&cpu, &ram, faultOf(err));
    return observe(&cpu, &ram, .none);
}

test "acq_rel matches the Arm ARM" {
    try vector.expectAll(vectors.In, vectors.Out, run, &vectors.all);
}

test "every vector is counted in covered and names the group" {
    try std.testing.expectEqual(vectors.all.len, vectors.covered.len);
    for (vectors.covered) |name| try std.testing.expectEqualStrings("acq_rel", name);
}
