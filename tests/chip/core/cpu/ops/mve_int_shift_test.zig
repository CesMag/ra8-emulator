//! Covers src/chip/core/cpu/ops/mve_int_shift.zig. The encodings come from
//! LLVM's assembler for -mcpu=cortex-m85 with MVE.
const std = @import("std");
const ra8 = @import("ra8");
const Cpu = ra8.chip.core.cpu.cpu.Cpu;
const Instr = ra8.chip.core.cpu.instr.Instr;
const shift = ra8.chip.core.cpu.ops.mve_int_shift;
const qreg = ra8.chip.core.cpu.mve.qreg;
const decode = ra8.chip.core.cpu.decode;

fn wide(hw1: u16, hw2: u16) Instr {
    return .{ .address = 0, .hw1 = hw1, .hw2 = hw2, .size = 4 };
}

fn run(cpu: *Cpu, hw1: u16, hw2: u16) !void {
    const instr = wide(hw1, hw2);
    const exec = shift.group.decode(instr) orelse return error.NotClaimed;
    try exec(cpu, instr);
}

/// Q1 holds the values (Qm) and Q2 the shifts (Qn) for `op q0, q1, q2`.
fn loaded(values: u128, shifts: u128) Cpu {
    var cpu: Cpu = .{ .bus = undefined };
    qreg.write(&cpu.fp.bank, 1, values);
    qreg.write(&cpu.fp.bank, 2, shifts);
    return cpu;
}

fn q0(cpu: *const Cpu) u128 {
    return qreg.read(&cpu.fp.bank, 0);
}

test "vshl.s8 shifts left and right by each lane's signed byte" {
    var cpu = loaded(0x80_01, 0xFF_03);
    try run(&cpu, 0xEF04, 0x0442);
    try std.testing.expectEqual(@as(u128, 0xC0_08), q0(&cpu));
    try std.testing.expectEqual(@as(u1, 0), cpu.fp.fpscr.qc);
}

test "vrshl.s8 rounds a right shift" {
    var cpu = loaded(0x05, 0xFF);
    try run(&cpu, 0xEF04, 0x0542);
    try std.testing.expectEqual(@as(u128, 0x03), q0(&cpu));
}

test "vqshl.u8 and vqrshl.s16 saturate and raise QC" {
    var cpu = loaded(0x80, 0x01);
    try run(&cpu, 0xFF04, 0x0452);
    try std.testing.expectEqual(@as(u128, 0xFF), q0(&cpu));
    try std.testing.expectEqual(@as(u1, 1), cpu.fp.fpscr.qc);
    cpu = loaded(0x4000, 0x0001);
    try run(&cpu, 0xEF14, 0x0552);
    try std.testing.expectEqual(@as(u128, 0x7FFF), q0(&cpu));
    try std.testing.expectEqual(@as(u1, 1), cpu.fp.fpscr.qc);
}

test "a masked-off lane that would saturate leaves QC clear" {
    var cpu = loaded(0x80_00, 0x01_01);
    cpu.fp.vpr = ra8.chip.core.cpu.mve.vpt.open(.{ .p0 = 0xFFFD }, 0b1000);
    try run(&cpu, 0xFF04, 0x0452);
    try std.testing.expectEqual(@as(u1, 0), cpu.fp.fpscr.qc);
    try std.testing.expectEqual(@as(u128, 0), q0(&cpu) & 0xFF00);
}

test "vshl.s32 q0, q7, q0 takes values from hw2 and shifts from hw1" {
    var cpu: Cpu = .{ .bus = undefined };
    qreg.write(&cpu.fp.bank, 7, 0x1);
    qreg.write(&cpu.fp.bank, 0, 0x4);
    try run(&cpu, 0xEF20, 0x044E);
    try std.testing.expectEqual(@as(u128, 0x10), q0(&cpu));
}

test "the table routes the T1 encodings here" {
    for ([_][2]u16{ .{ 0xEF14, 0x0442 }, .{ 0xFF24, 0x0542 }, .{ 0xEF04, 0x0452 }, .{ 0xFF24, 0x0552 } }) |e| {
        const hit = decode.decode(wide(e[0], e[1])) orelse return error.NotClaimed;
        try std.testing.expectEqualStrings("mve_int_shift", hit.group);
    }
}

test "unclaimed: size 3, Q8+, the pairwise space" {
    try std.testing.expect(shift.group.decode(wide(0xEF34, 0x0442)) == null);
    try std.testing.expect(shift.group.decode(wide(0xEF44, 0x0442)) == null);
    try std.testing.expect(shift.group.decode(wide(0xEF04, 0x0462)) == null);
    try std.testing.expect(shift.group.decode(wide(0xEF04, 0x0642)) == null);
}
