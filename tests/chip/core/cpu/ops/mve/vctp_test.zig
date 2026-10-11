//! Covers src/chip/core/cpu/ops/mve/vctp.zig. The encodings come from LLVM's
//! assembler for -mcpu=cortex-m85 with MVE.
const std = @import("std");
const ra8 = @import("ra8");
const Cpu = ra8.chip.core.cpu.cpu.Cpu;
const Instr = ra8.chip.core.cpu.instr.Instr;
const vctp = ra8.chip.core.cpu.ops.mve.vctp;
const vpt = ra8.chip.core.cpu.mve.vpt;
const decode = ra8.chip.core.cpu.decode;

fn wide(hw1: u16, hw2: u16) Instr {
    return .{ .address = 0, .hw1 = hw1, .hw2 = hw2, .size = 4 };
}

fn run(cpu: *Cpu, hw1: u16, hw2: u16) !void {
    const instr = wide(hw1, hw2);
    const exec = vctp.group.decode(instr) orelse return error.NotClaimed;
    try exec(cpu, instr);
}

test "the fields of vctp.8 r0, .16 r3, .32 r12 and .64 r1" {
    try std.testing.expectEqual(vctp.Fields{ .size = 0, .rn = 0 }, vctp.fields(wide(0xF000, 0xE801)).?);
    try std.testing.expectEqual(vctp.Fields{ .size = 1, .rn = 3 }, vctp.fields(wide(0xF013, 0xE801)).?);
    try std.testing.expectEqual(vctp.Fields{ .size = 2, .rn = 12 }, vctp.fields(wide(0xF02C, 0xE801)).?);
    try std.testing.expectEqual(vctp.Fields{ .size = 3, .rn = 1 }, vctp.fields(wide(0xF031, 0xE801)).?);
}

test "outside a block VCTP sets the first Rn elements" {
    var cpu: Cpu = .{ .bus = undefined };
    cpu.fp.vpr.p0 = 0xAAAA;
    cpu.regs.set(12, 3);
    try run(&cpu, 0xF02C, 0xE801);
    try std.testing.expectEqual(@as(u16, 0x0FFF), cpu.fp.vpr.p0);
    cpu.regs.set(1, 1);
    try run(&cpu, 0xF031, 0xE801);
    try std.testing.expectEqual(@as(u16, 0x00FF), cpu.fp.vpr.p0);
    cpu.regs.set(3, 100);
    try run(&cpu, 0xF013, 0xE801);
    try std.testing.expectEqual(@as(u16, 0xFFFF), cpu.fp.vpr.p0);
    cpu.regs.set(0, 0);
    try run(&cpu, 0xF000, 0xE801);
    try std.testing.expectEqual(@as(u16, 0x0000), cpu.fp.vpr.p0);
}

test "inside a block VCTP ANDs with the predicate and advances" {
    var cpu: Cpu = .{ .bus = undefined };
    cpu.fp.vpr = vpt.open(.{ .p0 = 0x00FF }, 0b1000);
    cpu.regs.set(12, 3);
    try run(&cpu, 0xF02C, 0xE801);
    try std.testing.expectEqual(@as(u16, 0x00FF), cpu.fp.vpr.p0);
    try std.testing.expect(!vpt.inBlock(cpu.fp.vpr));
}

test "SP and PC as Rn are not claimed" {
    try std.testing.expect(vctp.fields(wide(0xF02D, 0xE801)) == null);
    try std.testing.expect(vctp.fields(wide(0xF02F, 0xE801)) == null);
}

test "the table routes VCTP here" {
    for ([_]u16{ 0xF000, 0xF013, 0xF02C, 0xF031 }) |hw1| {
        const hit = decode.decode(wide(hw1, 0xE801)) orelse return error.NotClaimed;
        try std.testing.expectEqualStrings("mve_vctp", hit.group);
    }
}
