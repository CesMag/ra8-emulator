//! Covers src/chip/core/cpu/ops/mve/beats.zig through the ops that use it:
//! an instruction resumed with EPSR.ECI set runs only its later beats.
const std = @import("std");
const ra8 = @import("ra8");
const Cpu = ra8.chip.core.cpu.cpu.Cpu;
const Instr = ra8.chip.core.cpu.instr.Instr;
const ops = ra8.chip.core.cpu.ops;
const qreg = ra8.chip.core.cpu.mve.qreg;
const it_state = ra8.chip.core.cpu.it_state;

fn wide(hw1: u16, hw2: u16) Instr {
    return .{ .address = 0, .hw1 = hw1, .hw2 = hw2, .size = 4 };
}

fn run(group: anytype, cpu: *Cpu, hw1: u16, hw2: u16) !void {
    const instr = wide(hw1, hw2);
    const exec = group.decode(instr) orelse return error.NotClaimed;
    try exec(cpu, instr);
}

fn withEci(it: u8) Cpu {
    var cpu: Cpu = .{ .bus = undefined };
    cpu.regs.xpsr = it_state.put(0, it);
    qreg.write(&cpu.fp.bank, 0, 0xAAAA_AAAA_AAAA_AAAA_AAAA_AAAA_AAAA_AAAA);
    qreg.write(&cpu.fp.bank, 1, 0x0000_0004_0000_0003_0000_0002_0000_0001);
    qreg.write(&cpu.fp.bank, 2, 0x0000_0010_0000_0010_0000_0010_0000_0010);
    return cpu;
}

test "vadd.i32 resumed after A0 and A1 writes only beats 2 and 3" {
    var cpu = withEci(0x20);
    try run(ops.mve.int.group, &cpu, 0xEF22, 0x0844);
    try std.testing.expectEqual(@as(u128, 0x0000_0014_0000_0013_AAAA_AAAA_AAAA_AAAA), qreg.read(&cpu.fp.bank, 0));
    try std.testing.expectEqual(@as(u8, 0), it_state.get(cpu.regs.xpsr));
}

test "B0 done carries over as A0 of the next instruction" {
    var cpu = withEci(0x50);
    try run(ops.mve.int.group, &cpu, 0xEF22, 0x0844);
    try std.testing.expectEqual(@as(u128, 0x0000_0014_AAAA_AAAA_AAAA_AAAA_AAAA_AAAA), qreg.read(&cpu.fp.bank, 0));
    try std.testing.expectEqual(@as(u8, 0x10), it_state.get(cpu.regs.xpsr));
    try run(ops.mve.int.group, &cpu, 0xEF22, 0x0844);
    try std.testing.expectEqual(@as(u128, 0x0000_0014_0000_0013_0000_0012_AAAA_AAAA), qreg.read(&cpu.fp.bank, 0));
    try std.testing.expectEqual(@as(u8, 0), it_state.get(cpu.regs.xpsr));
}

test "an open IT block is not ECI: every beat runs and IT is left alone" {
    var cpu = withEci(0x28);
    try run(ops.mve.int.group, &cpu, 0xEF22, 0x0844);
    try std.testing.expectEqual(@as(u128, 0x0000_0014_0000_0013_0000_0012_0000_0011), qreg.read(&cpu.fp.bank, 0));
    try std.testing.expectEqual(@as(u8, 0x28), it_state.get(cpu.regs.xpsr));
}

test "vpnot resumed after A0 keeps beat 0 of P0" {
    var cpu = withEci(0x10);
    cpu.fp.vpr.p0 = 0x00F0;
    try run(ops.mve.vpred.group, &cpu, 0xFE31, 0x0F4D);
    try std.testing.expectEqual(@as(u16, 0xFF00), cpu.fp.vpr.p0);
}

test "the last tail-predicated iteration writes only the elements LR has left" {
    var cpu = withEci(0);
    cpu.fp.fpscr.ltpsize = 2;
    cpu.regs.lr = 3;
    try run(ops.mve.int.group, &cpu, 0xEF22, 0x0844);
    try std.testing.expectEqual(@as(u128, 0xAAAA_AAAA_0000_0013_0000_0012_0000_0011), qreg.read(&cpu.fp.bank, 0));
}

test "a tail-predicated iteration before the last writes every lane" {
    var cpu = withEci(0);
    cpu.fp.fpscr.ltpsize = 2;
    cpu.regs.lr = 5;
    try run(ops.mve.int.group, &cpu, 0xEF22, 0x0844);
    try std.testing.expectEqual(@as(u128, 0x0000_0014_0000_0013_0000_0012_0000_0011), qreg.read(&cpu.fp.bank, 0));
}

test "outside a tail-predicated loop LR does not mask anything" {
    var cpu = withEci(0);
    cpu.regs.lr = 1;
    try run(ops.mve.int.group, &cpu, 0xEF22, 0x0844);
    try std.testing.expectEqual(@as(u128, 0x0000_0014_0000_0013_0000_0012_0000_0011), qreg.read(&cpu.fp.bank, 0));
}

test "tail predication and VCTP combine: VCTP.8 with LR 2 of 32-bit elements" {
    var cpu = withEci(0);
    cpu.fp.fpscr.ltpsize = 2;
    cpu.regs.lr = 2;
    cpu.regs.set(0, 16);
    try run(ops.mve.vctp.group, &cpu, 0xF000, 0xE801);
    try std.testing.expectEqual(@as(u16, 0x00FF), cpu.fp.vpr.p0);
}
