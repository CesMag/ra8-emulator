//! Covers src/chip/core/cpu/conformance/base/fp_mem_vectors.zig: each vector
//! runs through the `fp_mem` group over the 1 KiB RAM fixture, patterned
//! memory and FP bank, with R0 (and SP for VPUSH/VPOP) as the base.
const std = @import("std");
const ra8 = @import("ra8");
const vector = ra8.chip.core.cpu.conformance.vector;
const vectors = ra8.chip.core.cpu.conformance.base.fp_mem_vectors;
const cpu_ns = ra8.chip.core.cpu;
const Cpu = cpu_ns.cpu.Cpu;
const Fpscr = ra8.chip.core.cpu.fpu.fpscr.Fpscr;
const fixture = @import("../../exception/ram.zig");

fn fill(ram: *fixture.Ram) void {
    var address: u32 = vectors.base;
    while (address < vectors.base + 0x400) : (address += 4) ram.putWord(address, vectors.memAt(address));
}

fn faultOf(err: anyerror) vectors.Fault {
    return switch (err) {
        error.Unaligned => .unaligned,
        error.Undefined => .undefined_instr,
        else => .other,
    };
}

fn run(in: vectors.In) vectors.Out {
    var ram: fixture.Ram = .{};
    fill(&ram);
    var cpu: Cpu = .{ .bus = ram.view() };
    cpu.regs.set(0, in.r0);
    if (in.base_reg == 13) cpu.regs.setSp(in.r0);
    for (0..32) |i| cpu.fp.bank.writeS(@intCast(i), vectors.bankAt(@intCast(i)));
    cpu.fp.fpscr = @bitCast(in.fpscr);
    cpu.fp.vpr = @bitCast(in.vpr);
    if (!in.secure) cpu.banked.current = .non_secure;
    const instr: cpu_ns.instr.Instr = .{ .address = in.address, .hw1 = in.hw1, .hw2 = in.hw2, .size = @intCast(in.size) };
    const exec = cpu_ns.ops.fp_mem.group.decode(instr) orelse return vectors.none;
    const ended: vectors.Fault = if (exec(&cpu, instr)) .none else |err| faultOf(err);
    return .{
        .fault = ended,
        .base = cpu.regs.get(in.base_reg),
        .s_a = cpu.fp.bank.readS(in.watch),
        .s_b = cpu.fp.bank.readS(in.watch +% 1),
        .mem_a = ram.word(in.at),
        .mem_b = ram.word(in.at + 4),
        .fpscr = @as(Fpscr, cpu.fp.fpscr).bits(),
        .vpr = @bitCast(cpu.fp.vpr),
    };
}

test "fp_mem matches the Arm ARM" {
    try vector.expectAll(vectors.In, vectors.Out, run, &vectors.all);
}

test "every vector is counted in covered and names the group" {
    try std.testing.expectEqual(vectors.all.len, vectors.covered.len);
    for (vectors.covered) |name| try std.testing.expectEqualStrings("fp_mem", name);
}
