//! Covers src/chip/core/cpu/ops/mve/int/vqdmlah.zig. The encodings come from
//! LLVM's assembler for -mcpu=cortex-m85 with MVE.
const std = @import("std");
const ra8 = @import("ra8");
const Cpu = ra8.chip.core.cpu.cpu.Cpu;
const Instr = ra8.chip.core.cpu.instr.Instr;
const vqdmlah = ra8.chip.core.cpu.ops.mve.int.vqdmlah;
const qreg = ra8.chip.core.cpu.mve.qreg;
const vpt = ra8.chip.core.cpu.mve.vpt;
const decode = ra8.chip.core.cpu.decode;

fn wide(hw1: u16, hw2: u16) Instr {
    return .{ .address = 0, .hw1 = hw1, .hw2 = hw2, .size = 4 };
}

fn run(cpu: *Cpu, hw1: u16, hw2: u16) !void {
    const instr = wide(hw1, hw2);
    const exec = vqdmlah.group.decode(instr) orelse return error.NotClaimed;
    try exec(cpu, instr);
}

test "vqdmlah.s8 q0, q1, r2 adds the doubled product's top half to Qda" {
    var cpu: Cpu = .{ .bus = undefined };
    qreg.write(&cpu.fp.bank, 0, 0x05);
    qreg.write(&cpu.fp.bank, 1, 0x40);
    cpu.regs.set(2, 0x02);
    try run(&cpu, 0xEE02, 0x0E62);
    try std.testing.expectEqual(@as(u128, 0x06), qreg.read(&cpu.fp.bank, 0));
    try std.testing.expectEqual(@as(u1, 0), cpu.fp.fpscr.qc);
}

test "vqdmlah.s8 saturates and sets QC" {
    var cpu: Cpu = .{ .bus = undefined };
    qreg.write(&cpu.fp.bank, 0, 0x7F);
    qreg.write(&cpu.fp.bank, 1, 0x80);
    cpu.regs.set(2, 0x80);
    try run(&cpu, 0xEE02, 0x0E62);
    try std.testing.expectEqual(@as(u32, 0x7F), qreg.elem(qreg.read(&cpu.fp.bank, 0), .byte, 0));
    try std.testing.expectEqual(@as(u1, 1), cpu.fp.fpscr.qc);
}

test "vqdmlash.s32 q0, q1, r2 multiplies by Qda and adds the scalar" {
    var cpu: Cpu = .{ .bus = undefined };
    qreg.write(&cpu.fp.bank, 0, 0x4000_0000);
    qreg.write(&cpu.fp.bank, 1, 0x4000_0000);
    cpu.regs.set(2, 3);
    try run(&cpu, 0xEE22, 0x1E62);
    try std.testing.expectEqual(@as(u32, 0x2000_0003), qreg.elem(qreg.read(&cpu.fp.bank, 0), .word, 0));
}

test "vqrdmlash.s8 q7, q6, r12 reads every register field and rounds" {
    var cpu: Cpu = .{ .bus = undefined };
    qreg.write(&cpu.fp.bank, 7, 0x01);
    qreg.write(&cpu.fp.bank, 6, 0x40);
    cpu.regs.set(12, 0);
    try run(&cpu, 0xEE0C, 0xFE4C);
    try std.testing.expectEqual(@as(u32, 1), qreg.elem(qreg.read(&cpu.fp.bank, 7), .byte, 0));
}

test "a masked-off lane neither changes nor sets QC" {
    var cpu: Cpu = .{ .bus = undefined };
    qreg.write(&cpu.fp.bank, 0, 0x7F);
    qreg.write(&cpu.fp.bank, 1, 0x80);
    cpu.regs.set(2, 0x80);
    cpu.fp.vpr = vpt.open(.{ .p0 = 0xFFFE }, 0b1000);
    try run(&cpu, 0xEE02, 0x0E62);
    try std.testing.expectEqual(@as(u32, 0x7F), qreg.elem(qreg.read(&cpu.fp.bank, 0), .byte, 0));
    try std.testing.expectEqual(@as(u1, 0), cpu.fp.fpscr.qc);
    try std.testing.expect(!vpt.inBlock(cpu.fp.vpr));
}

test "the table routes all four here" {
    for ([_][2]u16{ .{ 0xEE02, 0x0E62 }, .{ 0xEE12, 0x0E42 }, .{ 0xEE22, 0x1E62 }, .{ 0xEE0C, 0xFE4C }, .{ 0xEE2A, 0x6E69 } }) |e| {
        const hit = decode.decode(wide(e[0], e[1])) orelse return error.NotClaimed;
        try std.testing.expectEqualStrings("mve_int_vqdmlah", hit.group);
    }
}

test "unclaimed: size 11, D or N set, Rm of SP or PC, VMLA's bit 0" {
    try std.testing.expect(vqdmlah.group.decode(wide(0xEE32, 0x0E62)) == null);
    try std.testing.expect(vqdmlah.group.decode(wide(0xEE42, 0x0E62)) == null);
    try std.testing.expect(vqdmlah.group.decode(wide(0xEE02, 0x0EE2)) == null);
    try std.testing.expect(vqdmlah.group.decode(wide(0xEE02, 0x0E6D)) == null);
    try std.testing.expect(vqdmlah.group.decode(wide(0xEE02, 0x0E6F)) == null);
    try std.testing.expect(vqdmlah.group.decode(wide(0xEE03, 0x0E62)) == null);
}
