//! Covers src/chip/core/cpu/ops/mve_vmaxv.zig. The encodings come from LLVM's
//! assembler for -mcpu=cortex-m85 with MVE.
const std = @import("std");
const ra8 = @import("ra8");
const Cpu = ra8.chip.core.cpu.cpu.Cpu;
const Instr = ra8.chip.core.cpu.instr.Instr;
const vmaxv = ra8.chip.core.cpu.ops.mve.vmaxv;
const qreg = ra8.chip.core.cpu.mve.qreg;
const vpt = ra8.chip.core.cpu.mve.vpt;
const decode = ra8.chip.core.cpu.decode;

fn wide(hw1: u16, hw2: u16) Instr {
    return .{ .address = 0, .hw1 = hw1, .hw2 = hw2, .size = 4 };
}

fn run(cpu: *Cpu, hw1: u16, hw2: u16) !void {
    const instr = wide(hw1, hw2);
    const exec = vmaxv.group.decode(instr) orelse return error.NotClaimed;
    try exec(cpu, instr);
}

const a: u128 = 0x80000000_7FFFFFFF_00FF7F80_FFFF0001;

test "vmaxv.s8 r1, q0 folds Rda with every byte" {
    var cpu: Cpu = .{ .bus = undefined };
    qreg.write(&cpu.fp.bank, 0, a);
    cpu.regs.set(1, 0x80);
    try run(&cpu, 0xEEE2, 0x1F00);
    try std.testing.expectEqual(@as(u32, 0x7F), cpu.regs.get(1));
}

test "vminv.u32 r12, q7 reads the Qm and Rda fields" {
    var cpu: Cpu = .{ .bus = undefined };
    qreg.write(&cpu.fp.bank, 7, a);
    cpu.regs.set(12, 0xFFFF_FFFF);
    try run(&cpu, 0xFEEA, 0xCF8E);
    try std.testing.expectEqual(@as(u32, 0x00FF_7F80), cpu.regs.get(12));
}

test "vmaxav.s8 r1, q0 and vminav.s16 r2, q3 take absolute values" {
    var cpu: Cpu = .{ .bus = undefined };
    qreg.write(&cpu.fp.bank, 0, a);
    qreg.write(&cpu.fp.bank, 3, a);
    try run(&cpu, 0xEEE0, 0x1F00);
    try std.testing.expectEqual(@as(u32, 0x80), cpu.regs.get(1));
    cpu.regs.set(2, 0xFFFF);
    try run(&cpu, 0xEEE4, 0x2F86);
    try std.testing.expectEqual(@as(u32, 0), cpu.regs.get(2));
}

test "inside a VPT block only active elements count and the block advances" {
    var cpu: Cpu = .{ .bus = undefined };
    qreg.write(&cpu.fp.bank, 0, a);
    cpu.regs.set(1, 0);
    cpu.fp.vpr = vpt.open(.{ .p0 = 0x00F0 }, 0b1000);
    try run(&cpu, 0xEEEA, 0x1F00);
    try std.testing.expectEqual(@as(u32, 0x00FF_7F80), cpu.regs.get(1));
    try std.testing.expect(!vpt.inBlock(cpu.fp.vpr));
}

test "the table routes all four here" {
    for ([_][2]u16{ .{ 0xEEE2, 0x1F00 }, .{ 0xFEE2, 0x1F00 }, .{ 0xEEE2, 0x1F80 }, .{ 0xEEE0, 0x1F00 }, .{ 0xEEE4, 0x2F86 } }) |e| {
        const hit = decode.decode(wide(e[0], e[1])) orelse return error.NotClaimed;
        try std.testing.expectEqualStrings("mve_vmaxv", hit.group);
    }
}

test "unclaimed: the FP size, U with abs, Rda of 13 and 15, M set" {
    try std.testing.expect(vmaxv.group.decode(wide(0xEEEE, 0x1F00)) == null);
    try std.testing.expect(vmaxv.group.decode(wide(0xFEE0, 0x1F00)) == null);
    try std.testing.expect(vmaxv.group.decode(wide(0xEEE2, 0xDF00)) == null);
    try std.testing.expect(vmaxv.group.decode(wide(0xEEE2, 0xFF00)) == null);
    try std.testing.expect(vmaxv.group.decode(wide(0xEEE2, 0x1F20)) == null);
}
