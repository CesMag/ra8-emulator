//! Covers src/chip/core/cpu/ops/mve/vcmp/vcmp.zig. The encodings come from LLVM's
//! assembler for -mcpu=cortex-m85 with MVE.
const std = @import("std");
const ra8 = @import("ra8");
const Cpu = ra8.chip.core.cpu.cpu.Cpu;
const Instr = ra8.chip.core.cpu.instr.Instr;
const vcmp = ra8.chip.core.cpu.ops.mve.vcmp;
const qreg = ra8.chip.core.cpu.mve.qreg;
const decode = ra8.chip.core.cpu.decode;

fn wide(hw1: u16, hw2: u16) Instr {
    return .{ .address = 0, .hw1 = hw1, .hw2 = hw2, .size = 4 };
}

fn run(cpu: *Cpu, hw1: u16, hw2: u16) !void {
    const instr = wide(hw1, hw2);
    const exec = vcmp.group.decode(instr) orelse return error.NotClaimed;
    try exec(cpu, instr);
}

test "vcmp.i8 eq, q0, q1 writes P0 and leaves no block open" {
    var cpu: Cpu = .{ .bus = undefined };
    qreg.write(&cpu.fp.bank, 0, 0x0102);
    qreg.write(&cpu.fp.bank, 1, 0x0302);
    try run(&cpu, 0xFE01, 0x0F02);
    try std.testing.expectEqual(@as(u16, 0xFFFD), cpu.fp.vpr.p0);
    try std.testing.expect(!ra8.chip.core.cpu.mve.vpt.inBlock(cpu.fp.vpr));
}

test "vcmp.s32 gt, q7, r12 compares Qn against Rm signed" {
    var cpu: Cpu = .{ .bus = undefined };
    qreg.write(&cpu.fp.bank, 7, 0xFFFFFFFF_00000005);
    cpu.regs.set(12, 1);
    try run(&cpu, 0xFE2F, 0x1F6C);
    try std.testing.expectEqual(@as(u16, 0x000F), cpu.fp.vpr.p0);
}

test "vpt.u8 hi opens a one-instruction block" {
    var cpu: Cpu = .{ .bus = undefined };
    qreg.write(&cpu.fp.bank, 0, 0x80);
    qreg.write(&cpu.fp.bank, 1, 0x7F);
    try run(&cpu, 0xFE41, 0x0F83);
    try std.testing.expectEqual(@as(u16, 0x0001), cpu.fp.vpr.p0);
    try std.testing.expectEqual(@as(u4, 0b1000), cpu.fp.vpr.mask01);
    try std.testing.expectEqual(@as(u4, 0b1000), cpu.fp.vpr.mask23);
}

test "inside a block, VCMP clears the bytes the block masks off" {
    var cpu: Cpu = .{ .bus = undefined };
    cpu.fp.vpr = ra8.chip.core.cpu.mve.vpt.open(.{ .p0 = 0x00FF }, 0b1000);
    try run(&cpu, 0xFE01, 0x0F02);
    try std.testing.expectEqual(@as(u16, 0x00FF), cpu.fp.vpr.p0);
    try std.testing.expect(!ra8.chip.core.cpu.mve.vpt.inBlock(cpu.fp.vpr));
}

test "VPT resumed after A0 retains completed P0 and opens the remaining mask" {
    var cpu: Cpu = .{ .bus = undefined };
    qreg.write(&cpu.fp.bank, 0, 0x80);
    qreg.write(&cpu.fp.bank, 1, 0x7F);
    cpu.fp.vpr.p0 = 0xA55A;
    cpu.regs.xpsr = ra8.chip.core.cpu.it_state.put(cpu.regs.xpsr, 0x10);
    try run(&cpu, 0xFE41, 0x0F83);
    try std.testing.expectEqual(@as(u4, 0b1000), cpu.fp.vpr.mask01);
    try std.testing.expectEqual(@as(u4, 0b1000), cpu.fp.vpr.mask23);
    try std.testing.expectEqual(@as(u16, 0x000A), cpu.fp.vpr.p0);
    try std.testing.expectEqual(@as(u8, 0), ra8.chip.core.cpu.it_state.get(cpu.regs.xpsr));
}

test "the table routes VCMP and VPT here" {
    for ([_][2]u16{ .{ 0xFE11, 0x0F82 }, .{ 0xFE21, 0x1F62 }, .{ 0xFE61, 0x0F02 }, .{ 0xFE61, 0xEF02 }, .{ 0xFE51, 0x1F62 } }) |e| {
        const hit = decode.decode(wide(e[0], e[1])) orelse return error.NotClaimed;
        try std.testing.expectEqualStrings("mve_vcmp", hit.group);
    }
}

test "unclaimed: VPNOT, VPSEL, VPST, the FP compares, Rm SP, Qm 8+" {
    try std.testing.expect(vcmp.group.decode(wide(0xFE31, 0x0F4D)) == null);
    try std.testing.expect(vcmp.group.decode(wide(0xFE33, 0x0F05)) == null);
    try std.testing.expect(vcmp.group.decode(wide(0xFE71, 0x0F4D)) == null);
    try std.testing.expect(vcmp.group.decode(wide(0xEE31, 0x0F02)) == null);
    try std.testing.expect(vcmp.group.decode(wide(0xFE01, 0x0F4D)) == null);
    try std.testing.expect(vcmp.group.decode(wide(0xFE01, 0x0F22)) == null);
}
