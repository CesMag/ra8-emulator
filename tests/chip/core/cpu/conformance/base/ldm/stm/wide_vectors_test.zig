//! Covers src/chip/core/cpu/conformance/base/ldm/stm/wide_vectors.zig: each
//! vector runs through the `ldm_stm_wide` group over the exception tests'
//! 1 KiB of RAM at 0x2000_0000, every word of it holding its pattern.
const std = @import("std");
const ra8 = @import("ra8");
const vector = ra8.chip.core.cpu.conformance.vector;
const vectors = ra8.chip.core.cpu.conformance.base.ldm.stm.wide_vectors;
const cpu_ns = ra8.chip.core.cpu;
const Cpu = cpu_ns.cpu.Cpu;
const fixture = @import("../../../../exception/ram.zig");

fn peek(ram: *fixture.Ram, address: u32) u32 {
    if (address < vectors.ram_base or address >= vectors.ram_end) return 0;
    return ram.word(address);
}

fn observe(cpu: *const Cpu, ram: *fixture.Ram, base: u32, ended: vectors.Fault) vectors.Out {
    const at = base & ~@as(u32, 3);
    return .{
        .fault = ended,
        .r0 = cpu.regs.get(0),
        .r1 = cpu.regs.get(1),
        .r2 = cpu.regs.get(2),
        .r3 = cpu.regs.get(3),
        .sp = cpu.regs.sp(),
        .lr = cpu.regs.get(14),
        .pc = cpu.regs.pc,
        .thumb = cpu.regs.xpsr & cpu_ns.regs.xpsr_bits.thumb != 0,
        .wm8 = peek(ram, at -% 8),
        .wm4 = peek(ram, at -% 4),
        .w0 = peek(ram, at),
        .w4 = peek(ram, at +% 4),
        .w8 = peek(ram, at +% 8),
    };
}

fn faultOf(err: anyerror) vectors.Fault {
    return switch (err) {
        error.Unmapped => .unmapped,
        error.Unaligned => .unaligned,
        else => .other,
    };
}

fn setUp(cpu: *Cpu, ram: *fixture.Ram, in: vectors.In) void {
    var address = vectors.ram_base;
    while (address < vectors.ram_end) : (address += 4) ram.putWord(address, vectors.pattern(address));
    for (0..13) |n| cpu.regs.set(@intCast(n), vectors.fill + @as(u32, @intCast(n)));
    cpu.regs.set(14, vectors.fill + 14);
    cpu.regs.setSp(vectors.sp_in);
    cpu.regs.pc = vectors.pc_in;
    const rn: u4 = @intCast(in.hw1 & 0xF);
    if (rn == 13) cpu.regs.setSp(in.base) else if (rn != 15) cpu.regs.set(rn, in.base);
}

fn run(in: vectors.In) vectors.Out {
    var ram: fixture.Ram = .{};
    var cpu: Cpu = .{ .bus = ram.view(), .regs = .{ .xpsr = cpu_ns.regs.xpsr_bits.thumb } };
    setUp(&cpu, &ram, in);
    const instr: cpu_ns.instr.Instr = .{ .address = vectors.pc_in, .hw1 = in.hw1, .hw2 = in.hw2, .size = @intCast(in.size) };
    const exec = cpu_ns.ops.ldm.stm.wide.group.decode(instr) orelse return vectors.none;
    exec(&cpu, instr) catch |err| return observe(&cpu, &ram, in.base, faultOf(err));
    return observe(&cpu, &ram, in.base, .none);
}

test "ldm_stm_wide matches the Arm ARM" {
    try vector.expectAll(vectors.In, vectors.Out, run, &vectors.all);
}

test "every vector is counted in covered and names the group" {
    try std.testing.expectEqual(vectors.all.len, vectors.covered.len);
    for (vectors.covered) |name| try std.testing.expectEqualStrings("ldm_stm_wide", name);
}
