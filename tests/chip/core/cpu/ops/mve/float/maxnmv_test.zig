//! Covers src/chip/core/cpu/ops/mve_float_maxnmv.zig. The encodings come from
//! LLVM's assembler for -mcpu=cortex-m85 with MVE floating point.
const std = @import("std");
const ra8 = @import("ra8");
const Cpu = ra8.chip.core.cpu.cpu.Cpu;
const Instr = ra8.chip.core.cpu.instr.Instr;
const maxnmv = ra8.chip.core.cpu.ops.mve.float.maxnmv;
const qreg = ra8.chip.core.cpu.mve.qreg;
const decode = ra8.chip.core.cpu.decode;

fn wide(hw1: u16, hw2: u16) Instr {
    return .{ .address = 0, .hw1 = hw1, .hw2 = hw2, .size = 4 };
}

fn run(cpu: *Cpu, hw1: u16, hw2: u16) !void {
    const instr = wide(hw1, hw2);
    const exec = maxnmv.group.decode(instr) orelse return error.NotClaimed;
    try exec(cpu, instr);
}

// q1 = {1, -5, 3, quiet NaN} as F32.
fn loaded(r0: u32) Cpu {
    var cpu: Cpu = .{ .bus = undefined };
    qreg.write(&cpu.fp.bank, 1, 0x7FC00000_40400000_C0A00000_3F800000);
    cpu.regs.set(0, r0);
    return cpu;
}

test "F32 folds from r0 = 2.0, a quiet NaN lane losing to the number" {
    const cases = [_]struct { hw1: u16, hw2: u16, out: u32 }{
        .{ .hw1 = 0xEEEE, .hw2 = 0x0F02, .out = 0x40400000 }, // vmaxnmv: 3
        .{ .hw1 = 0xEEEE, .hw2 = 0x0F82, .out = 0xC0A00000 }, // vminnmv: -5
        .{ .hw1 = 0xEEEC, .hw2 = 0x0F02, .out = 0x40A00000 }, // vmaxnmav: 5
        .{ .hw1 = 0xEEEC, .hw2 = 0x0F82, .out = 0x3F800000 }, // vminnmav: 1
    };
    for (cases) |c| {
        var cpu = loaded(0x40000000);
        try run(&cpu, c.hw1, c.hw2);
        try std.testing.expectEqual(c.out, cpu.regs.get(0));
        try std.testing.expectEqual(@as(u1, 0), cpu.fp.fpscr.ioc);
    }
}

test "vminnmav.f32 keeps the scalar's sign: r0 = -7.0 stays" {
    var cpu = loaded(0xC0E00000);
    try run(&cpu, 0xEEEC, 0x0F82);
    try std.testing.expectEqual(@as(u32, 0xC0E00000), cpu.regs.get(0));
}

test "F16: vmaxnmv.f16 r12, q7 zero-extends; vminnmav.f16 lr, q3" {
    var cpu: Cpu = .{ .bus = undefined };
    qreg.write(&cpu.fp.bank, 7, 0x3C00_3C00_3C00_4400_3C00_3C00_3C00_3C00);
    cpu.regs.set(12, 0xFFFF_4000);
    try run(&cpu, 0xFEEE, 0xCF0E);
    try std.testing.expectEqual(@as(u32, 0x4400), cpu.regs.get(12));
    qreg.write(&cpu.fp.bank, 3, 0xC000_C000_C000_C000_C000_C000_C000_C000);
    cpu.regs.set(14, 0x3C00);
    try run(&cpu, 0xFEEC, 0xEF86);
    try std.testing.expectEqual(@as(u32, 0x3C00), cpu.regs.get(14));
}

test "the table routes every form here, not to the integer VMAXV" {
    for ([_][2]u16{
        .{ 0xEEEE, 0x0F02 }, .{ 0xEEEE, 0x0F82 }, .{ 0xEEEC, 0x0F02 },
        .{ 0xEEEC, 0x0F82 }, .{ 0xFEEE, 0xCF0E }, .{ 0xFEEC, 0xEF86 },
    }) |e| {
        const hit = decode.decode(wide(e[0], e[1])) orelse return error.NotClaimed;
        try std.testing.expectEqualStrings("mve_float_maxnmv", hit.group);
    }
}

test "unclaimed: M set, Rda 13 or 15, bit 0 of hw1 set" {
    try std.testing.expect(maxnmv.fields(wide(0xEEEE, 0x0F22)) == null);
    try std.testing.expect(maxnmv.fields(wide(0xEEEE, 0xDF02)) == null);
    try std.testing.expect(maxnmv.fields(wide(0xEEEE, 0xFF02)) == null);
    try std.testing.expect(maxnmv.fields(wide(0xEEEF, 0x0F02)) == null);
}
