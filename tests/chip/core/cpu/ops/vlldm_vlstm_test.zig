//! Covers src/chip/core/cpu/ops/vlldm_vlstm.zig. Encodings checked against
//! zig cc (LLVM) for cortex-m85:
//!
//!     ec20 0a00  vlstm r0
//!     ec30 0a00  vlldm r0
//!     ec23 0a80  vlstm r3, {d0-d31}
//!     ec33 0a80  vlldm r3, {d0-d31}
const std = @import("std");
const ra8 = @import("ra8");
const vl = ra8.chip.core.cpu.ops.vlldm_vlstm;
const table = ra8.chip.core.cpu.ops.table;
const Cpu = ra8.chip.core.cpu.cpu.Cpu;
const Instr = ra8.chip.core.cpu.instr.Instr;
const control_bits = ra8.chip.core.cpu.regs.control_bits;
const cpacr = ra8.chip.core.cpu.fpu.cpacr;
const fixture = @import("../exception/ram.zig");

const vlstm = [2]u16{ 0xEC20, 0x0A00 };
const vlldm = [2]u16{ 0xEC30, 0x0A00 };
const vlstm_t2 = [2]u16{ 0xEC23, 0x0A80 };
const vlldm_t2 = [2]u16{ 0xEC33, 0x0A80 };
const frame: u32 = fixture.base + 0x200;

fn wide(pair: [2]u16) Instr {
    return .{ .address = fixture.code, .hw1 = pair[0], .hw2 = pair[1], .size = 4 };
}

fn run(cpu: *Cpu, pair: [2]u16) !void {
    const g = if (pair[1] & vl.encodings.t2_bit != 0) vl.group_t2 else vl.group;
    try g.decode(wide(pair)).?(cpu, wide(pair));
}

/// Secure, CP10 enabled, SFPA and FPCA set, LSPEN clear, every S register
/// and VPR non-zero, R0 and R3 at the frame.
fn ready(ram: *fixture.Ram) !Cpu {
    var cpu = try fixture.boot(ram);
    cpu.fp.cpacr = cpacr.full_access;
    cpu.regs.control |= control_bits.sfpa | control_bits.fpca;
    cpu.fp.context.fpccr.lspen = 0;
    for (0..32) |i| cpu.fp.bank.writeS(@intCast(i), 0x3F80_0000 + @as(u32, @intCast(i)));
    cpu.fp.fpscr = @TypeOf(cpu.fp.fpscr).fromBits(0x0004_0000);
    cpu.fp.vpr = @bitCast(@as(u32, 0x0000_ABCD));
    cpu.regs.set(0, frame);
    cpu.regs.set(3, frame);
    return cpu;
}

test "vlstm stores S0-S15, FPSCR and VPR and clears FPCA, registers kept with TS clear" {
    var ram: fixture.Ram = .{};
    var cpu = try ready(&ram);
    try run(&cpu, vlstm);
    for (0..16) |i| try std.testing.expectEqual(0x3F80_0000 + @as(u32, @intCast(i)), ram.word(frame + vl.slot(i)));
    try std.testing.expectEqual(cpu.fp.fpscr.bits(), ram.word(frame + vl.offset.fpscr));
    try std.testing.expectEqual(@as(u32, 0xABCD), ram.word(frame + vl.offset.vpr));
    try std.testing.expectEqual(@as(u32, 0), ram.word(frame + vl.slot(16)));
    try std.testing.expectEqual(@as(u32, 0), cpu.regs.control & control_bits.fpca);
    try std.testing.expectEqual(@as(u32, 0x3F80_0005), cpu.fp.bank.readS(5));
}

test "vlstm with TS set stores S16-S31 after VPR and clears the context" {
    var ram: fixture.Ram = .{};
    var cpu = try ready(&ram);
    cpu.fp.context.fpccr.ts = 1;
    try run(&cpu, vlstm_t2);
    try std.testing.expectEqual(@as(u32, 0x3F80_0010), ram.word(frame + 0x48));
    try std.testing.expectEqual(@as(u32, 0x3F80_001F), ram.word(frame + 0x84));
    try std.testing.expectEqual(@as(u32, 0), cpu.fp.bank.readS(31));
    try std.testing.expectEqual(@as(u32, 0), cpu.fp.fpscr.bits());
    try std.testing.expectEqual(@as(u32, 0), @as(u32, @bitCast(cpu.fp.vpr)));
}

test "vlldm loads back what vlstm stored and sets FPCA" {
    var ram: fixture.Ram = .{};
    var cpu = try ready(&ram);
    cpu.fp.context.fpccr.ts = 1;
    try run(&cpu, vlstm);
    try run(&cpu, vlldm_t2);
    try std.testing.expectEqual(@as(u32, 0x3F80_0007), cpu.fp.bank.readS(7));
    try std.testing.expectEqual(@as(u32, 0x3F80_001E), cpu.fp.bank.readS(30));
    try std.testing.expectEqual(@as(u32, 0x0004_0000), cpu.fp.fpscr.bits());
    try std.testing.expectEqual(@as(u32, 0xABCD), @as(u32, @bitCast(cpu.fp.vpr)));
    try std.testing.expect(cpu.regs.control & control_bits.fpca != 0);
}

test "vlstm with LSPEN set arms lazy preservation and writes nothing" {
    var ram: fixture.Ram = .{};
    var cpu = try ready(&ram);
    cpu.fp.context.fpccr.lspen = 1;
    try run(&cpu, vlstm);
    try std.testing.expectEqual(frame, cpu.fp.context.fpcar);
    try std.testing.expectEqual(@as(u1, 1), cpu.fp.context.fpccr.lspact);
    try std.testing.expectEqual(@as(u1, 1), cpu.fp.context.fpccr.s);
    try std.testing.expectEqual(@as(u32, 0), ram.word(frame));
    try std.testing.expectEqual(@as(u32, 0), cpu.regs.control & control_bits.fpca);
}

test "vlldm with LSPACT set only clears it" {
    var ram: fixture.Ram = .{};
    var cpu = try ready(&ram);
    cpu.fp.context.fpccr.lspact = 1;
    try run(&cpu, vlldm);
    try std.testing.expectEqual(@as(u1, 0), cpu.fp.context.fpccr.lspact);
    try std.testing.expectEqual(@as(u32, 0x3F80_0002), cpu.fp.bank.readS(2));
    try std.testing.expect(cpu.regs.control & control_bits.fpca != 0);
}

test "SFPA clear is a NOP, Non-secure is UNDEFINED, Rn must be 8-byte aligned" {
    var ram: fixture.Ram = .{};
    var cpu = try ready(&ram);
    cpu.regs.control &= ~control_bits.sfpa;
    try run(&cpu, vlstm);
    try std.testing.expectEqual(@as(u32, 0), ram.word(frame));
    try std.testing.expect(cpu.regs.control & control_bits.fpca != 0);
    cpu.regs.control |= control_bits.sfpa;
    cpu.regs.set(0, frame + 4);
    try std.testing.expectError(error.Unaligned, run(&cpu, vlstm));
    cpu.banked.current = .non_secure;
    try std.testing.expectError(error.Undefined, run(&cpu, vlldm));
}

test "T1 and T2 split by group, Rn = PC unclaimed, and the table routes each once" {
    try std.testing.expect(vl.group.decode(wide(vlstm_t2)) == null);
    try std.testing.expect(vl.group_t2.decode(wide(vlstm)) == null);
    try std.testing.expect(vl.fields(wide(.{ 0xEC2F, 0x0A00 })) == null);
    for ([_][2]u16{ vlstm, vlldm, vlstm_t2, vlldm_t2 }) |pair| {
        var claimed: usize = 0;
        for (table.groups) |g| {
            if (g.decode(wide(pair)) != null) claimed += 1;
        }
        try std.testing.expectEqual(@as(usize, 1), claimed);
    }
}

test "CPACR refusing CP10 is NOCP before any store or state change" {
    var ram: fixture.Ram = .{};
    var cpu = try ready(&ram);
    cpu.fp.cpacr = 0;
    try std.testing.expectError(error.NoCoprocessor, run(&cpu, vlstm));
    try std.testing.expectError(error.NoCoprocessor, run(&cpu, vlldm_t2));
    try std.testing.expectEqual(@as(u32, 0), ram.word(frame));
    try std.testing.expect(cpu.regs.control & control_bits.fpca != 0);
    try std.testing.expectEqual(@as(u32, 0x3F80_0002), cpu.fp.bank.readS(2));
}

test "privileged-only CP10 refuses unprivileged Thread mode" {
    var ram: fixture.Ram = .{};
    var cpu = try ready(&ram);
    cpu.fp.cpacr = 0x0050_0000;
    try run(&cpu, vlstm);
    try std.testing.expect(cpu.regs.control & control_bits.fpca == 0);
    if (!cpu.regs.handlerMode()) {
        cpu.regs.control |= control_bits.npriv | control_bits.fpca;
        try std.testing.expectError(error.NoCoprocessor, run(&cpu, vlstm));
    }
}

test "VLSTM with LSPACT already set is LSERR before any store" {
    var ram: fixture.Ram = .{};
    var cpu = try ready(&ram);
    cpu.fp.context.fpccr.lspact = 1;
    try std.testing.expectError(error.LazyStateError, run(&cpu, vlstm));
    try std.testing.expectError(error.LazyStateError, run(&cpu, vlstm_t2));
    try std.testing.expectEqual(@as(u32, 0), ram.word(frame));
    try std.testing.expect(cpu.regs.control & control_bits.fpca != 0);
    try std.testing.expectEqual(@as(u1, 1), cpu.fp.context.fpccr.lspact);
}

test "LSERR is checked before alignment; VLLDM with LSPACT skips alignment" {
    var ram: fixture.Ram = .{};
    var cpu = try ready(&ram);
    cpu.fp.context.fpccr.lspact = 1;
    cpu.regs.set(0, frame + 4);
    try std.testing.expectError(error.LazyStateError, run(&cpu, vlstm));
    try run(&cpu, vlldm);
    try std.testing.expectEqual(@as(u1, 0), cpu.fp.context.fpccr.lspact);
    try std.testing.expectError(error.Unaligned, run(&cpu, vlldm));
}
