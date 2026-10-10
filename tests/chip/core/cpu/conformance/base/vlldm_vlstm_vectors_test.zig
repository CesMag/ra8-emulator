//! Covers src/chip/core/cpu/conformance/base/vlldm_vlstm_vectors.zig: each
//! vector runs through the `vlldm_vlstm` group over the 1 KiB RAM fixture
//! with a patterned bank and frame. `runWith` is shared with the T2 test.
const std = @import("std");
const ra8 = @import("ra8");
const vector = ra8.chip.core.cpu.conformance.vector;
const vectors = ra8.chip.core.cpu.conformance.base.vlldm_vlstm_vectors;
const cpu_ns = ra8.chip.core.cpu;
const Cpu = cpu_ns.cpu.Cpu;
const Fpscr = ra8.chip.core.cpu.fpu.fpscr.Fpscr;
const fixture = @import("../../exception/ram.zig");

fn faultOf(err: anyerror) vectors.Fault {
    return switch (err) {
        error.Undefined => .undefined_instr,
        error.NoCoprocessor => .nocp,
        error.LazyStateError => .lserr,
        error.Unaligned => .unaligned,
        else => .other,
    };
}

fn setUp(cpu: *Cpu, ram: *fixture.Ram, in: vectors.In) void {
    var address: u32 = vectors.base;
    while (address < vectors.base + 0x400) : (address += 4) ram.putWord(address, vectors.memAt(address));
    ram.putWord(vectors.a + 0x40, vectors.frame_fpscr);
    ram.putWord(vectors.a + 0x44, vectors.frame_vpr);
    for (0..32) |i| cpu.fp.bank.writeS(@intCast(i), vectors.bankAt(@intCast(i)));
    cpu.fp.fpscr = Fpscr.fromBits(vectors.fpscr_in);
    cpu.fp.vpr = @bitCast(vectors.vpr_in);
    cpu.fp.cpacr = in.cpacr;
    cpu.fp.context.fpccr.lspen = in.lspen;
    cpu.fp.context.fpccr.ts = in.ts;
    cpu.fp.context.fpccr.lspact = in.lspact;
    cpu.regs.control = in.control;
    cpu.regs.set(@intCast(in.hw1 & 0xF), in.r0);
    if (!in.secure) cpu.banked.current = .non_secure;
}

pub fn runWith(comptime group: anytype, in: vectors.In) vectors.Out {
    var ram: fixture.Ram = .{};
    var cpu: Cpu = .{ .bus = ram.view() };
    setUp(&cpu, &ram, in);
    const instr: cpu_ns.instr.Instr = .{ .address = 0x2000_0100, .hw1 = in.hw1, .hw2 = in.hw2, .size = @intCast(in.size) };
    const exec = group.decode(instr) orelse return vectors.none;
    const ended: vectors.Fault = if (exec(&cpu, instr)) .none else |err| faultOf(err);
    return .{
        .fault = ended,
        .s0 = cpu.fp.bank.readS(0),
        .s16 = cpu.fp.bank.readS(16),
        .fpscr = cpu.fp.fpscr.bits(),
        .vpr = @bitCast(cpu.fp.vpr),
        .m0 = ram.word(vectors.a),
        .m16 = ram.word(vectors.a + 0x48),
        .mfpscr = ram.word(vectors.a + 0x40),
        .mvpr = ram.word(vectors.a + 0x44),
        .control = cpu.regs.control,
        .lspact = cpu.fp.context.fpccr.lspact,
        .fpcar = cpu.fp.context.fpcar,
    };
}

fn run(in: vectors.In) vectors.Out {
    return runWith(cpu_ns.ops.vlldm_vlstm.group, in);
}

test "vlldm_vlstm matches the Arm ARM" {
    try vector.expectAll(vectors.In, vectors.Out, run, &vectors.all);
}

test "every vector is counted in covered and names the group" {
    try std.testing.expectEqual(vectors.all.len, vectors.covered.len);
    for (vectors.covered) |name| try std.testing.expectEqualStrings("vlldm_vlstm", name);
}
