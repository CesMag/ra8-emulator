//! Covers src/chip/core/cpu/ops/mve_vpst.zig. The encodings come from LLVM's
//! assembler for -mcpu=cortex-m85 with MVE.
const std = @import("std");
const ra8 = @import("ra8");
const Cpu = ra8.chip.core.cpu.cpu.Cpu;
const Instr = ra8.chip.core.cpu.instr.Instr;
const mve_vpst = ra8.chip.core.cpu.ops.mve.vpst;
const it_state = ra8.chip.core.cpu.it_state;
const decode = ra8.chip.core.cpu.decode;

fn wide(hw1: u16, hw2: u16) Instr {
    return .{ .address = 0, .hw1 = hw1, .hw2 = hw2, .size = 4 };
}

fn run(cpu: *Cpu, hw1: u16, hw2: u16) !void {
    const instr = wide(hw1, hw2);
    const exec = mve_vpst.group.decode(instr) orelse return error.NotClaimed;
    try exec(cpu, instr);
}

test "the assembler's VPST masks decode as written" {
    const cases = [_]struct { hw1: u16, hw2: u16, mask: u4 }{
        .{ .hw1 = 0xFE71, .hw2 = 0x0F4D, .mask = 0b1000 }, // vpst
        .{ .hw1 = 0xFE31, .hw2 = 0x8F4D, .mask = 0b0100 }, // vpstt
        .{ .hw1 = 0xFE71, .hw2 = 0x8F4D, .mask = 0b1100 }, // vpste
        .{ .hw1 = 0xFE71, .hw2 = 0x4F4D, .mask = 0b1010 }, // vpstee
        .{ .hw1 = 0xFE31, .hw2 = 0x2F4D, .mask = 0b0001 }, // vpsttttt
        .{ .hw1 = 0xFE71, .hw2 = 0xEF4D, .mask = 0b1111 }, // vpstete
    };
    for (cases) |c| try std.testing.expectEqual(c.mask, mve_vpst.mask(wide(c.hw1, c.hw2)));
}

test "vpste opens the block in both beat pairs and keeps P0" {
    var cpu: Cpu = .{ .bus = undefined };
    cpu.fp.vpr.p0 = 0x1234;
    try run(&cpu, 0xFE71, 0x8F4D);
    try std.testing.expectEqual(@as(u4, 0b1100), cpu.fp.vpr.mask01);
    try std.testing.expectEqual(@as(u4, 0b1100), cpu.fp.vpr.mask23);
    try std.testing.expectEqual(@as(u16, 0x1234), cpu.fp.vpr.p0);
}

test "vpst resumed after beat A0 opens the remaining VPT mask and retires ECI" {
    var cpu: Cpu = .{ .bus = undefined };
    cpu.regs.xpsr = it_state.put(cpu.regs.xpsr, 0x10);
    try run(&cpu, 0xFE71, 0x8F4D);
    try std.testing.expectEqual(@as(u4, 0b1100), cpu.fp.vpr.mask01);
    try std.testing.expectEqual(@as(u4, 0b1100), cpu.fp.vpr.mask23);
    try std.testing.expectEqual(@as(u8, 0), it_state.get(cpu.regs.xpsr));
}

test "the table permits ECI for VPST" {
    const hit = decode.decode(wide(0xFE71, 0x8F4D)) orelse return error.NotClaimed;
    try std.testing.expectEqual(ra8.chip.core.cpu.op.Eci.beat_wise, hit.eci);
}

test "unclaimed: a zero mask, other hw2 bits, the narrow size" {
    try std.testing.expect(mve_vpst.group.decode(wide(0xFE31, 0x0F4D)) == null);
    try std.testing.expect(mve_vpst.group.decode(wide(0xFE71, 0x0F4F)) == null);
    try std.testing.expect(mve_vpst.group.decode(wide(0xFE71, 0x1F4D)) == null);
    try std.testing.expect(mve_vpst.group.decode(.{ .address = 0, .hw1 = 0xFE71, .hw2 = 0, .size = 2 }) == null);
}
