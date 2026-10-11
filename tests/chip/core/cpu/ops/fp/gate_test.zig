//! Covers src/chip/core/cpu/ops/fp/gate.zig: ExecuteFPCheck() opening a new FP
//! context in front of a gated group, per the Arm ARM (DDI0553).
const std = @import("std");
const ra8 = @import("ra8");
const Cpu = ra8.chip.core.cpu.cpu.Cpu;
const Instr = ra8.chip.core.cpu.instr.Instr;
const ops = ra8.chip.core.cpu.ops;
const fpca: u32 = 1 << 2;

const gated = ops.fp.gate.gated(ops.fp.arith.group);

fn wide(hw1: u16, hw2: u16) Instr {
    return .{ .address = 0, .hw1 = hw1, .hw2 = hw2, .size = 4 };
}

fn run(cpu: *Cpu, hw1: u16, hw2: u16) !void {
    const instr = wide(hw1, hw2);
    const exec = gated.decode(instr) orelse return error.NotClaimed;
    try exec(cpu, instr);
}

fn fresh() Cpu {
    var cpu: Cpu = .{ .bus = undefined };
    cpu.fp.cpacr = ra8.chip.core.cpu.fpu.cpacr.full_access;
    return cpu;
}

test "the gated group keeps its name and claims the same encodings" {
    try std.testing.expectEqualStrings(ops.fp.arith.group.name, gated.name);
    try std.testing.expect(gated.decode(wide(0xEE30, 0x0A81)) != null);
    try std.testing.expect(gated.decode(wide(0xF000, 0xB800)) == null);
}

test "the first FP op sets FPCA and seeds FPSCR from FPDSCR before it runs" {
    var cpu = fresh();
    cpu.fp.context.writeFpdscr(0x00C0_0000); // RMode towards zero
    cpu.fp.fpscr = @bitCast(@as(u32, 0x8000_0010)); // N, IXC
    cpu.fp.bank.writeS(1, 0x3F80_0000); // 1.0
    cpu.fp.bank.writeS(2, 0x3380_0000); // 2^-24
    try run(&cpu, 0xEE30, 0x0A81); // vadd.f32 s0, s1, s2
    try std.testing.expectEqual(fpca | ra8.chip.core.cpu.regs.control_bits.sfpa, cpu.regs.control & (fpca | ra8.chip.core.cpu.regs.control_bits.sfpa));
    try std.testing.expectEqual(@as(u1, 1), cpu.fp.context.fpccr.s);
    // Rounded towards zero, so the sum stays 1.0 and only IXC is set.
    try std.testing.expectEqual(@as(u32, 0x3F80_0000), cpu.fp.bank.readS(0));
    try std.testing.expectEqual(@as(u32, 0x00C4_0010), cpu.fp.fpscr.bits());
}

test "with FPCA already set the FPSCR carries over" {
    var cpu = fresh();
    cpu.regs.control = fpca | ra8.chip.core.cpu.regs.control_bits.sfpa;
    cpu.fp.context.writeFpdscr(0x00C0_0000);
    cpu.fp.fpscr = @bitCast(@as(u32, 0x8004_0000));
    cpu.fp.bank.writeS(1, 0x3F80_0000);
    cpu.fp.bank.writeS(2, 0x3F80_0000);
    try run(&cpu, 0xEE30, 0x0A81);
    try std.testing.expectEqual(@as(u32, 0x4000_0000), cpu.fp.bank.readS(0));
    try std.testing.expectEqual(@as(u32, 0x8004_0000), cpu.fp.fpscr.bits());
}

test "ASPEN clear leaves CONTROL alone" {
    var cpu = fresh();
    cpu.fp.context.writeFpccr(0);
    try run(&cpu, 0xEE30, 0x0A81);
    try std.testing.expectEqual(@as(u32, 0), cpu.regs.control);
}

test "the decode table routes FP encodings through the gate" {
    var cpu = fresh();
    const hit = ra8.chip.core.cpu.decode.decode(wide(0xEE30, 0x0A81)) orelse return error.NotClaimed;
    try hit.exec(&cpu, wide(0xEE30, 0x0A81));
    try std.testing.expectEqual(fpca, cpu.regs.control & fpca);
}

const fixture = @import("../../exception/ram.zig");

test "a pending lazy preservation is written before the FP op runs" {
    var ram: fixture.Ram = .{};
    var cpu = try fixture.boot(&ram);
    const at = fixture.msp_top - 0x48;
    cpu.fp.context.writeFpcar(at);
    cpu.fp.context.fpccr.lspact = 1;
    cpu.fp.bank.writeS(0, 0x1111_1111);
    cpu.fp.bank.writeS(1, 0x3F80_0000);
    cpu.fp.bank.writeS(2, 0x3F80_0000);
    cpu.fp.fpscr = @bitCast(@as(u32, 0x2004_0000));
    try run(&cpu, 0xEE30, 0x0A81); // vadd.f32 s0, s1, s2
    try std.testing.expectEqual(@as(u1, 0), cpu.fp.context.fpccr.lspact);
    // The old S0 and FPSCR went to the frame; the add then ran on fresh state.
    try std.testing.expectEqual(@as(u32, 0x1111_1111), ram.word(at));
    try std.testing.expectEqual(@as(u32, 0x2004_0000), ram.word(at + 0x40));
    try std.testing.expectEqual(@as(u32, 0x4000_0000), cpu.fp.bank.readS(0));
}

test "no lazy preservation pending leaves memory alone" {
    var ram: fixture.Ram = .{};
    var cpu = try fixture.boot(&ram);
    const at = fixture.msp_top - 0x48;
    cpu.fp.context.writeFpcar(at);
    cpu.fp.bank.writeS(0, 0x1111_1111);
    try run(&cpu, 0xEE30, 0x0A81);
    try std.testing.expectEqual(@as(u32, 0), ram.word(at));
}

/// A Secure lazy context pending at `at` while Non-secure code runs.
fn secureLazy(ram: *fixture.Ram, ts: u1) !Cpu {
    var cpu = try fixture.boot(ram);
    const at = fixture.msp_top - 0x88;
    cpu.fp.context.writeFpcar(at);
    cpu.fp.context.fpccr.lspact = 1;
    cpu.fp.context.fpccr.s = 1;
    cpu.fp.context.fpccr.ts = ts;
    cpu.banked.current = .non_secure;
    for (0..32) |i| cpu.fp.bank.writeS(@intCast(i), 0x3F80_0000 + @as(u32, @intCast(i)));
    try run(&cpu, 0xEE30, 0x0A81); // vadd.f32 s0, s1, s2
    return cpu;
}

test "a Secure context saved from Non-secure code is cleared before the op runs" {
    var ram: fixture.Ram = .{};
    const cpu = try secureLazy(&ram, 0);
    const at = fixture.msp_top - 0x88;
    try std.testing.expectEqual(@as(u32, 0x3F80_0001), ram.word(at + 4));
    try std.testing.expectEqual(@as(u32, 0), cpu.fp.bank.readS(0)); // 0 + 0
    try std.testing.expectEqual(@as(u32, 0), cpu.fp.bank.readS(15));
    try std.testing.expectEqual(@as(u32, 0x3F80_0010), cpu.fp.bank.readS(16));
}

test "with FPCCR.TS the Secure S16-S31 are saved and cleared too" {
    var ram: fixture.Ram = .{};
    const cpu = try secureLazy(&ram, 1);
    const at = fixture.msp_top - 0x88;
    try std.testing.expectEqual(@as(u32, 0x3F80_0010), ram.word(at + 0x48));
    try std.testing.expectEqual(@as(u32, 0), cpu.fp.bank.readS(16));
    try std.testing.expectEqual(@as(u32, 0), cpu.fp.bank.readS(31));
}

test "Secure gate reopens context when FPCA is set but SFPA is clear" {
    var cpu = fresh();
    cpu.regs.control = fpca;
    cpu.fp.context.writeFpdscr(0x00C0_0000);
    cpu.fp.fpscr = @bitCast(@as(u32, 0x8004_0000));
    cpu.fp.vpr = @bitCast(@as(u32, 0x0084_1234));
    cpu.fp.bank.writeS(1, 0x3F80_0000);
    cpu.fp.bank.writeS(2, 0x3F80_0000);
    try run(&cpu, 0xEE30, 0x0A81);
    try std.testing.expectEqual(
        fpca | ra8.chip.core.cpu.regs.control_bits.sfpa,
        cpu.regs.control & (fpca | ra8.chip.core.cpu.regs.control_bits.sfpa),
    );
    try std.testing.expectEqual(@as(u32, 1), cpu.fp.context.fpccr.s);
    try std.testing.expectEqual(@as(u32, 0x00C4_0000), cpu.fp.fpscr.bits());
    try std.testing.expectEqual(@as(u32, 0), @as(u32, @bitCast(cpu.fp.vpr)));
}

const memmap = ra8.chip.core.memmap;
const usage_handler: u32 = fixture.base + 0x1C0;
const hard_handler: u32 = fixture.base + 0x1E0;
const usgfaultena: u32 = 1 << 18;
const nocp_bit: u32 = 1 << 19;
const forced: u32 = 1 << 30;

/// vadd.f32 s0, s1, s2 at fixture.code, with the FPU off unless `cpacr`
/// grants it, and UsageFault enabled when `usage` is set.
fn faddOn(ram: *fixture.Ram, cpacr: u32, usage: bool) !Cpu {
    ram.putWord(fixture.base + 3 * 4, hard_handler | 1);
    ram.putWord(fixture.base + 6 * 4, usage_handler | 1);
    if (usage) ram.putWord(memmap.scb.shcsr, usgfaultena);
    ram.putHalf(fixture.code, 0xEE30);
    ram.putHalf(fixture.code + 2, 0x0A81);
    var cpu = try fixture.boot(ram);
    cpu.fp.cpacr = cpacr;
    cpu.fp.bank.writeS(1, 0x3F80_0000);
    cpu.fp.bank.writeS(2, 0x3F80_0000);
    return cpu;
}

test "CPACR.CP10 off: an FP op takes UsageFault.NOCP and touches no FP state" {
    var ram: fixture.Ram = .{};
    var cpu = try faddOn(&ram, 0, true);
    try std.testing.expectEqual(@as(?ra8.chip.core.cpu.cpu.Stop, null), cpu.step());
    try std.testing.expectEqual(usage_handler, cpu.regs.pc);
    try std.testing.expectEqual(nocp_bit, ram.word(memmap.scb.cfsr));
    try std.testing.expectEqual(fixture.code, ram.word(cpu.regs.sp() + 24));
    try std.testing.expectEqual(@as(u32, 0), cpu.fp.bank.readS(0));
    try std.testing.expectEqual(@as(u32, 0), cpu.regs.control & fpca);
}

test "privileged-only CPACR.CP10 refuses unprivileged Thread mode" {
    var ram: fixture.Ram = .{};
    var cpu = try faddOn(&ram, 0x0050_0000, true);
    cpu.regs.control |= 1; // nPRIV
    try std.testing.expectEqual(@as(?ra8.chip.core.cpu.cpu.Stop, null), cpu.step());
    try std.testing.expectEqual(usage_handler, cpu.regs.pc);
    try std.testing.expectEqual(nocp_bit, ram.word(memmap.scb.cfsr));
}

test "CPACR.CP10 on: the same op runs" {
    var ram: fixture.Ram = .{};
    var cpu = try faddOn(&ram, ra8.chip.core.cpu.fpu.cpacr.full_access, true);
    try std.testing.expectEqual(@as(?ra8.chip.core.cpu.cpu.Stop, null), cpu.step());
    try std.testing.expectEqual(fixture.code + 4, cpu.regs.pc);
    try std.testing.expectEqual(@as(u32, 0x4000_0000), cpu.fp.bank.readS(0));
    try std.testing.expectEqual(@as(u32, 0), ram.word(memmap.scb.cfsr));
}

test "NOCP with USGFAULTENA clear escalates to HardFault with HFSR.FORCED" {
    var ram: fixture.Ram = .{};
    var cpu = try faddOn(&ram, 0, false);
    try std.testing.expectEqual(@as(?ra8.chip.core.cpu.cpu.Stop, null), cpu.step());
    try std.testing.expectEqual(hard_handler, cpu.regs.pc);
    try std.testing.expectEqual(nocp_bit, ram.word(memmap.scb.cfsr));
    try std.testing.expectEqual(forced, ram.word(memmap.scb.hfsr));
}
