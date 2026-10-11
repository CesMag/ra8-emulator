//! Covers src/chip/core/cpu/ops/mve_int_pair.zig. The encodings come from
//! LLVM's assembler for -mcpu=cortex-m85 with MVE.
const std = @import("std");
const ra8 = @import("ra8");
const Cpu = ra8.chip.core.cpu.cpu.Cpu;
const Instr = ra8.chip.core.cpu.instr.Instr;
const pair = ra8.chip.core.cpu.ops.mve_int_pair;
const qreg = ra8.chip.core.cpu.mve.qreg;
const decode = ra8.chip.core.cpu.decode;

fn wide(hw1: u16, hw2: u16) Instr {
    return .{ .address = 0, .hw1 = hw1, .hw2 = hw2, .size = 4 };
}

fn run(cpu: *Cpu, hw1: u16, hw2: u16) !void {
    const instr = wide(hw1, hw2);
    const exec = pair.group.decode(instr) orelse return error.NotClaimed;
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

test "vqadd.s8 clamps and raises QC; vqadd.u32 does not wrap" {
    var cpu = loaded(0x7F, 0x01);
    try run(&cpu, 0xEF02, 0x0054);
    try std.testing.expectEqual(@as(u128, 0x7F), q0(&cpu));
    try std.testing.expectEqual(@as(u1, 1), cpu.fp.fpscr.qc);
    cpu = loaded(0xFFFF_FFF0, 0x20);
    try run(&cpu, 0xFF22, 0x0054);
    try std.testing.expectEqual(@as(u128, 0xFFFF_FFFF), q0(&cpu) & 0xFFFF_FFFF);
}

test "vqsub.u8 floors at zero and vqsub.s16 without overflow leaves QC clear" {
    var cpu = loaded(0x05, 0x09);
    try run(&cpu, 0xFF02, 0x0254);
    try std.testing.expectEqual(@as(u128, 0), q0(&cpu));
    try std.testing.expectEqual(@as(u1, 1), cpu.fp.fpscr.qc);
    cpu = loaded(0x0010, 0x0001);
    try run(&cpu, 0xEF12, 0x0254);
    try std.testing.expectEqual(@as(u128, 0x000F), q0(&cpu));
    try std.testing.expectEqual(@as(u1, 0), cpu.fp.fpscr.qc);
}

test "a masked-off lane that would saturate leaves QC clear" {
    var cpu = loaded(0x7F00, 0x0100);
    cpu.fp.vpr = ra8.chip.core.cpu.mve.vpt.open(.{ .p0 = 0xFFFD }, 0b1000);
    try run(&cpu, 0xEF02, 0x0054);
    try std.testing.expectEqual(@as(u1, 0), cpu.fp.fpscr.qc);
    try std.testing.expectEqual(@as(u128, 0), q0(&cpu) & 0xFF00);
}

test "the pairwise group: vhadd, vrhadd, vhsub, vmax, vmin, vabd" {
    const cases = [_]struct { hw1: u16, hw2: u16, expect: u128 }{
        .{ .hw1 = 0xFF02, .hw2 = 0x0044, .expect = 0x80 }, // vhadd.u8 0xFF+0x01 >> 1
        .{ .hw1 = 0xFF02, .hw2 = 0x0144, .expect = 0x80 }, // vrhadd.u8
        .{ .hw1 = 0xEF02, .hw2 = 0x0244, .expect = 0xFF }, // vhsub.s8 (-1 - 1) >> 1
        .{ .hw1 = 0xEF02, .hw2 = 0x0644, .expect = 0x01 }, // vmax.s8
        .{ .hw1 = 0xFF02, .hw2 = 0x0654, .expect = 0x01 }, // vmin.u8
        .{ .hw1 = 0xEF02, .hw2 = 0x0744, .expect = 0x02 }, // vabd.s8 |-1 - 1|
    };
    for (cases) |c| {
        var cpu = loaded(0xFF, 0x01);
        try run(&cpu, c.hw1, c.hw2);
        try std.testing.expectEqual(c.expect, q0(&cpu) & 0xFF);
    }
}

test "activeLanes follows each element's lowest byte" {
    try std.testing.expectEqual(@as(u128, 0xFFFF_FFFF), pair.activeLanes(0x0001, .word));
    try std.testing.expectEqual(@as(u128, 0xFFFF_0000), pair.activeLanes(0x0004, .half));
}

test "the table routes the T1 encodings here" {
    for ([_][2]u16{ .{ 0xEF12, 0x0054 }, .{ 0xFF22, 0x0254 }, .{ 0xEF02, 0x0744 }, .{ 0xFF22, 0x0144 } }) |e| {
        const hit = decode.decode(wide(e[0], e[1])) orelse return error.NotClaimed;
        try std.testing.expectEqualStrings("mve_int_pair", hit.group);
    }
}

test "unclaimed: size 3, Q8+, other opcodes" {
    try std.testing.expect(pair.group.decode(wide(0xEF32, 0x0054)) == null);
    try std.testing.expect(pair.group.decode(wide(0xEF42, 0x0054)) == null);
    try std.testing.expect(pair.group.decode(wide(0xEF02, 0x0754)) == null);
    try std.testing.expect(pair.group.decode(wide(0xEF02, 0x0844)) == null);
}
