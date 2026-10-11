//! Covers src/chip/core/cpu/ops/mve/int/scalar.zig. The encodings come from
//! LLVM's assembler for -mcpu=cortex-m85 with MVE, as `op q0, q1, r2`.
const std = @import("std");
const ra8 = @import("ra8");
const Cpu = ra8.chip.core.cpu.cpu.Cpu;
const Instr = ra8.chip.core.cpu.instr.Instr;
const scalar = ra8.chip.core.cpu.ops.mve.int.scalar;
const qreg = ra8.chip.core.cpu.mve.qreg;
const decode = ra8.chip.core.cpu.decode;

fn wide(hw1: u16, hw2: u16) Instr {
    return .{ .address = 0, .hw1 = hw1, .hw2 = hw2, .size = 4 };
}

/// Runs `hw1 hw2` with Q1 = `n` and R2 = `rm`, returning Q0.
fn run(cpu: *Cpu, hw1: u16, hw2: u16, n: u128, rm: u32) !u128 {
    qreg.write(&cpu.fp.bank, 1, n);
    cpu.regs.set(2, rm);
    const instr = wide(hw1, hw2);
    const exec = scalar.group.decode(instr) orelse return error.NotClaimed;
    try exec(cpu, instr);
    return qreg.read(&cpu.fp.bank, 0);
}

fn fresh() Cpu {
    return .{ .bus = undefined };
}

test "vadd, vsub and vmul use Rm in every lane" {
    var cpu = fresh();
    try std.testing.expectEqual(@as(u128, 0x02_03_01), try run(&cpu, 0xEE03, 0x0F42, 0x01_FF, 0x1_02) & 0xFF_FFFF);
    try std.testing.expectEqual(@as(u128, 0xFFFF_FFFE), try run(&cpu, 0xEE23, 0x1F42, 5, 7) & 0xFFFF_FFFF);
    try std.testing.expectEqual(@as(u128, 0x0F), try run(&cpu, 0xEE03, 0x1E62, 0x03, 0x05) & 0xFF);
}

test "vqadd.s8 and vqsub.u16 saturate and raise QC" {
    var cpu = fresh();
    try std.testing.expectEqual(@as(u128, 0x7F), try run(&cpu, 0xEE02, 0x0F62, 0x7F, 1) & 0xFF);
    try std.testing.expectEqual(@as(u1, 1), cpu.fp.fpscr.qc);
    cpu = fresh();
    try std.testing.expectEqual(@as(u128, 0), try run(&cpu, 0xFE12, 0x1F62, 0x0001, 2) & 0xFFFF);
    try std.testing.expectEqual(@as(u1, 1), cpu.fp.fpscr.qc);
}

test "vhadd.u8 and vhsub.s16 halve without overflow" {
    var cpu = fresh();
    try std.testing.expectEqual(@as(u128, 0x80), try run(&cpu, 0xFE02, 0x0F42, 0xFF, 0x01) & 0xFF);
    try std.testing.expectEqual(@as(u128, 0xFFFE), try run(&cpu, 0xEE12, 0x1F42, 0, 3) & 0xFFFF);
}

test "vqdmulh.s16 saturates and vqrdmulh.s16 rounds" {
    var cpu = fresh();
    try std.testing.expectEqual(@as(u128, 0x7FFF), try run(&cpu, 0xEE13, 0x0E62, 0x8000, 0x8000) & 0xFFFF);
    try std.testing.expectEqual(@as(u1, 1), cpu.fp.fpscr.qc);
    cpu = fresh();
    try std.testing.expectEqual(@as(u128, 1), try run(&cpu, 0xFE13, 0x0E62, 0x4000, 1) & 0xFFFF);
    try std.testing.expectEqual(@as(u1, 0), cpu.fp.fpscr.qc);
}

test "a masked-off lane that would saturate leaves QC clear" {
    var cpu = fresh();
    cpu.fp.vpr = ra8.chip.core.cpu.mve.vpt.open(.{ .p0 = 0x0001 }, 0b1000);
    _ = try run(&cpu, 0xEE02, 0x0F62, 0x7F_00, 1);
    try std.testing.expectEqual(@as(u1, 0), cpu.fp.fpscr.qc);
}

test "vadd.i32 q0, q7, r12 takes Qn from hw1 and Rm from hw2" {
    var cpu = fresh();
    qreg.write(&cpu.fp.bank, 7, 0x10);
    cpu.regs.set(12, 0x20);
    const instr = wide(0xEE2F, 0x0F4C);
    try (scalar.group.decode(instr) orelse return error.NotClaimed)(&cpu, instr);
    try std.testing.expectEqual(@as(u128, 0x30), qreg.read(&cpu.fp.bank, 0) & 0xFFFF_FFFF);
}

test "the table routes the T2 encodings here" {
    const cases = [_][2]u16{
        .{ 0xEE13, 0x0F42 }, .{ 0xEE23, 0x1F42 }, .{ 0xEE23, 0x1E62 }, .{ 0xFE22, 0x0F62 },
        .{ 0xEE02, 0x1F62 }, .{ 0xEE02, 0x0F42 }, .{ 0xFE22, 0x1F42 }, .{ 0xEE13, 0x0E62 },
    };
    for (cases) |e| {
        const hit = decode.decode(wide(e[0], e[1])) orelse return error.NotClaimed;
        try std.testing.expectEqualStrings("mve_int_scalar", hit.group);
    }
}

test "unclaimed: Rm SP or PC, size 3, Q8+" {
    try std.testing.expect(scalar.group.decode(wide(0xEE03, 0x0F4D)) == null);
    try std.testing.expect(scalar.group.decode(wide(0xEE03, 0x0F4F)) == null);
    try std.testing.expect(scalar.group.decode(wide(0xEE33, 0x0F42)) == null);
    try std.testing.expect(scalar.group.decode(wide(0xEE43, 0x0F42)) == null);
}

test "vbrsr reverses each lane and keeps Rm's bottom byte of bits" {
    var cpu = fresh();
    try std.testing.expectEqual(@as(u128, 0x80_01), try run(&cpu, 0xFE03, 0x1E62, 0x01_80, 8) & 0xFFFF);
    try std.testing.expectEqual(@as(u128, 0b011), try run(&cpu, 0xFE13, 0x1E62, 0b0110, 0x103) & 0xFFFF);
    try std.testing.expectEqual(@as(u128, 0), try run(&cpu, 0xFE23, 0x1E62, 0xFFFF_FFFF, 0x100) & 0xFFFF_FFFF);
}

test "vbrsr writes only the lanes VPR leaves live" {
    var cpu = fresh();
    qreg.write(&cpu.fp.bank, 0, 0xAAAA_0000);
    cpu.fp.vpr = ra8.chip.core.cpu.mve.vpt.open(.{ .p0 = 0x0003 }, 0b1000);
    try std.testing.expectEqual(@as(u128, 0xAAAA_8000), try run(&cpu, 0xFE13, 0x1E62, 0x0001_0001, 16) & 0xFFFF_FFFF);
}
