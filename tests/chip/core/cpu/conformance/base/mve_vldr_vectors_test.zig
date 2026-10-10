//! Covers src/chip/core/cpu/conformance/base/mve_vldr_vectors.zig: each vector
//! runs through the `mve_vldr` group over the exception tests' 1 KiB of RAM
//! at 0x2000_0000, with the window at 0x2000_0200 filled first, then Qd, Rn,
//! VPR, the IT byte, LR and FPSCR set. It reads back the fault, Qd, Rn, the
//! window and VPR.
const std = @import("std");
const ra8 = @import("ra8");
const vector = ra8.chip.core.cpu.conformance.vector;
const vectors = ra8.chip.core.cpu.conformance.base.mve_vldr_vectors;
const cpu_ns = ra8.chip.core.cpu;
const Cpu = cpu_ns.cpu.Cpu;
const it_state = cpu_ns.it_state;
const fixture = @import("../../exception/ram.zig");

fn writeQ(cpu: *Cpu, n: u3, value: u128) void {
    for (0..4) |k| cpu.fp.bank.writeS(@as(u5, n) * 4 + @as(u5, @intCast(k)), @truncate(value >> @intCast(32 * k)));
}

fn readQ(cpu: *Cpu, n: u3) u128 {
    var out: u128 = 0;
    for (0..4) |k| out |= @as(u128, cpu.fp.bank.readS(@as(u5, n) * 4 + @as(u5, @intCast(k)))) << @intCast(32 * k);
    return out;
}

fn faultOf(err: anyerror) vectors.Fault {
    return switch (err) {
        error.Unaligned => .unaligned,
        error.Unmapped => .unmapped,
        else => .other,
    };
}

fn observe(cpu: *Cpu, ram: *fixture.Ram, in: vectors.In, fault: vectors.Fault) vectors.Out {
    const offset = vectors.window - fixture.base;
    var mem: [4]u128 = undefined;
    for (0..4) |j| mem[j] = std.mem.readInt(u128, ram.bytes[offset + 16 * j ..][0..16], .little);
    return .{
        .fault = fault,
        .qd = readQ(cpu, @intCast(in.hw2 >> 13)),
        .rn = cpu.regs.get(@intCast(in.hw1 & 0xF)),
        .mem = mem,
        .vpr = @bitCast(cpu.fp.vpr),
    };
}

fn run(in: vectors.In) vectors.Out {
    var ram: fixture.Ram = .{};
    const offset = vectors.window - fixture.base;
    for (0..64) |i| ram.bytes[offset + i] = vectors.fill(i);
    var cpu: Cpu = .{ .bus = ram.view(), .regs = .{ .xpsr = cpu_ns.regs.xpsr_bits.thumb } };
    writeQ(&cpu, @intCast(in.hw2 >> 13), in.qd);
    cpu.fp.vpr = @bitCast(in.vpr);
    cpu.fp.fpscr = @bitCast(in.fpscr);
    cpu.regs.xpsr = it_state.put(cpu.regs.xpsr, in.it);
    cpu.regs.set(14, in.lr);
    const rn: u4 = @intCast(in.hw1 & 0xF);
    if (rn != 15) cpu.regs.set(rn, in.base);
    const instr: cpu_ns.instr.Instr = .{ .address = 0x2000_0100, .hw1 = in.hw1, .hw2 = in.hw2, .size = @intCast(in.size) };
    const exec = cpu_ns.ops.mve_vldr.group.decode(instr) orelse return vectors.none;
    exec(&cpu, instr) catch |err| return observe(&cpu, &ram, in, faultOf(err));
    return observe(&cpu, &ram, in, .none);
}

test "mve_vldr matches the Arm ARM" {
    try vector.expectAll(vectors.In, vectors.Out, run, &vectors.all);
}

test "every vector is counted in covered and names the group" {
    try std.testing.expectEqual(vectors.all.len, vectors.covered.len);
    for (vectors.covered) |name| try std.testing.expectEqualStrings("mve_vldr", name);
}
