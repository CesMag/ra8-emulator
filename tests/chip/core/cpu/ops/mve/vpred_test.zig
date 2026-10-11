//! Covers src/chip/core/cpu/ops/mve_vpred.zig. The encodings come from LLVM's
//! assembler for -mcpu=cortex-m85 with MVE.
const std = @import("std");
const ra8 = @import("ra8");
const Cpu = ra8.chip.core.cpu.cpu.Cpu;
const Instr = ra8.chip.core.cpu.instr.Instr;
const vpred = ra8.chip.core.cpu.ops.mve.vpred;
const qreg = ra8.chip.core.cpu.mve.qreg;
const vpt = ra8.chip.core.cpu.mve.vpt;
const decode = ra8.chip.core.cpu.decode;

fn wide(hw1: u16, hw2: u16) Instr {
    return .{ .address = 0, .hw1 = hw1, .hw2 = hw2, .size = 4 };
}

fn run(cpu: *Cpu, hw1: u16, hw2: u16) !void {
    const instr = wide(hw1, hw2);
    const exec = vpred.group.decode(instr) orelse return error.NotClaimed;
    try exec(cpu, instr);
}

test "vpnot outside a block inverts every P0 bit" {
    var cpu: Cpu = .{ .bus = undefined };
    cpu.fp.vpr.p0 = 0x0F0F;
    try run(&cpu, 0xFE31, 0x0F4D);
    try std.testing.expectEqual(@as(u16, 0xF0F0), cpu.fp.vpr.p0);
}

test "vpnot inside a block clears the bytes it masks off and advances" {
    var cpu: Cpu = .{ .bus = undefined };
    cpu.fp.vpr = vpt.open(.{ .p0 = 0x00FF }, 0b1000);
    try run(&cpu, 0xFE31, 0x0F4D);
    try std.testing.expectEqual(@as(u16, 0x0000), cpu.fp.vpr.p0);
    try std.testing.expect(!vpt.inBlock(cpu.fp.vpr));
}

test "vpsel q0, q1, q2 takes Qn where P0 is set and Qm elsewhere" {
    var cpu: Cpu = .{ .bus = undefined };
    qreg.write(&cpu.fp.bank, 1, 0x1111_1111);
    qreg.write(&cpu.fp.bank, 2, 0x2222_2222);
    cpu.fp.vpr.p0 = 0x0005;
    try run(&cpu, 0xFE33, 0x0F05);
    try std.testing.expectEqual(@as(u128, 0x2211_2211), qreg.read(&cpu.fp.bank, 0));
}

test "vpsel q7, q0, q0 and q0, q7, q0 read the register fields" {
    var cpu: Cpu = .{ .bus = undefined };
    qreg.write(&cpu.fp.bank, 0, 0xAB);
    try run(&cpu, 0xFE31, 0xEF01);
    try std.testing.expectEqual(@as(u128, 0xAB), qreg.read(&cpu.fp.bank, 7));
    qreg.write(&cpu.fp.bank, 7, 0xCD);
    cpu.fp.vpr.p0 = 0xFFFF;
    try run(&cpu, 0xFE3F, 0x0F01);
    try std.testing.expectEqual(@as(u128, 0xCD), qreg.read(&cpu.fp.bank, 0));
}

test "the table routes VPNOT and VPSEL here" {
    for ([_][2]u16{ .{ 0xFE31, 0x0F4D }, .{ 0xFE33, 0x0F05 }, .{ 0xFE3F, 0x0F01 }, .{ 0xFE31, 0x0F0F } }) |e| {
        const hit = decode.decode(wide(e[0], e[1])) orelse return error.NotClaimed;
        try std.testing.expectEqualStrings("mve_vpred", hit.group);
    }
}

test "unclaimed: VPST, Q8+ operands, VCMP space" {
    try std.testing.expect(vpred.group.decode(wide(0xFE71, 0x0F4D)) == null);
    try std.testing.expect(vpred.group.decode(wide(0xFE73, 0x0F05)) == null);
    try std.testing.expect(vpred.group.decode(wide(0xFE33, 0x0F25)) == null);
    try std.testing.expect(vpred.group.decode(wide(0xFE21, 0x0F02)) == null);
}
