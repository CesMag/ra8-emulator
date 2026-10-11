//! Covers src/chip/core/cpu/ops/mve/int/mulh.zig. The encodings come from
//! LLVM's assembler for -mcpu=cortex-m85 with MVE, as `op q0, q1, q2`.
const std = @import("std");
const ra8 = @import("ra8");
const Cpu = ra8.chip.core.cpu.cpu.Cpu;
const Instr = ra8.chip.core.cpu.instr.Instr;
const mulh = ra8.chip.core.cpu.ops.mve.int.mulh;
const qreg = ra8.chip.core.cpu.mve.qreg;
const decode = ra8.chip.core.cpu.decode;

fn wide(hw1: u16, hw2: u16) Instr {
    return .{ .address = 0, .hw1 = hw1, .hw2 = hw2, .size = 4 };
}

fn run(cpu: *Cpu, hw1: u16, hw2: u16) !void {
    const instr = wide(hw1, hw2);
    const exec = mulh.group.decode(instr) orelse return error.NotClaimed;
    try exec(cpu, instr);
}

fn loaded(a: u128, b: u128) Cpu {
    var cpu: Cpu = .{ .bus = undefined };
    qreg.write(&cpu.fp.bank, 1, a);
    qreg.write(&cpu.fp.bank, 2, b);
    return cpu;
}

fn q0(cpu: *const Cpu) u128 {
    return qreg.read(&cpu.fp.bank, 0);
}

test "vmulh.s8 and vmulh.u8 keep the high byte of each product" {
    var cpu = loaded(0xFF_40, 0xFF_40);
    try run(&cpu, 0xEE03, 0x0E05);
    try std.testing.expectEqual(@as(u128, 0x00_10), q0(&cpu));
    cpu = loaded(0xFF_40, 0xFF_40);
    try run(&cpu, 0xFE03, 0x0E05);
    try std.testing.expectEqual(@as(u128, 0xFE_10), q0(&cpu));
}

test "vrmulh.u8 rounds the high byte" {
    var cpu = loaded(0x80, 0x81);
    try run(&cpu, 0xFE03, 0x1E05);
    try std.testing.expectEqual(@as(u128, 0x41), q0(&cpu));
    cpu = loaded(0x80, 0x81);
    try run(&cpu, 0xFE03, 0x0E05);
    try std.testing.expectEqual(@as(u128, 0x40), q0(&cpu));
}

test "vqdmulh.s16 saturates min*min and raises QC" {
    var cpu = loaded(0x8000, 0x8000);
    try run(&cpu, 0xEF12, 0x0B44);
    try std.testing.expectEqual(@as(u128, 0x7FFF), q0(&cpu));
    try std.testing.expectEqual(@as(u1, 1), cpu.fp.fpscr.qc);
}

test "vqrdmulh.s16 rounds where vqdmulh truncates" {
    var cpu = loaded(0x4000, 0x0001);
    try run(&cpu, 0xEF12, 0x0B44);
    try std.testing.expectEqual(@as(u128, 0), q0(&cpu));
    cpu = loaded(0x4000, 0x0001);
    try run(&cpu, 0xFF12, 0x0B44);
    try std.testing.expectEqual(@as(u128, 1), q0(&cpu));
    try std.testing.expectEqual(@as(u1, 0), cpu.fp.fpscr.qc);
}

test "a masked-off lane that would saturate leaves QC clear" {
    var cpu = loaded(0x8000_0000, 0x8000_0000);
    cpu.fp.vpr = ra8.chip.core.cpu.mve.vpt.open(.{ .p0 = 0xFFF3 }, 0b1000);
    try run(&cpu, 0xEF12, 0x0B44);
    try std.testing.expectEqual(@as(u1, 0), cpu.fp.fpscr.qc);
}

test "the table routes the T1 encodings here" {
    for ([_][2]u16{ .{ 0xEE13, 0x0E05 }, .{ 0xFE23, 0x1E05 }, .{ 0xEF22, 0x0B44 }, .{ 0xFF02, 0x0B44 } }) |e| {
        const hit = decode.decode(wide(e[0], e[1])) orelse return error.NotClaimed;
        try std.testing.expectEqualStrings("mve_int_mulh", hit.group);
    }
}

test "unclaimed: size 3, Q8+, a neighbouring tail" {
    try std.testing.expect(mulh.group.decode(wide(0xEE33, 0x0E05)) == null);
    try std.testing.expect(mulh.group.decode(wide(0xEE43, 0x0E05)) == null);
    try std.testing.expect(mulh.group.decode(wide(0xEF32, 0x0B44)) == null);
    try std.testing.expect(mulh.group.decode(wide(0xEF12, 0x0B54)) == null);
}
