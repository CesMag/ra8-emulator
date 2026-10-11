//! Covers src/chip/core/cpu/ops/mve_reduce.zig. The encodings come from GNU as
//! for armv8.1-m.main+mve.
const std = @import("std");
const ra8 = @import("ra8");
const Cpu = ra8.chip.core.cpu.cpu.Cpu;
const Instr = ra8.chip.core.cpu.instr.Instr;
const reduce = ra8.chip.core.cpu.ops.mve_reduce;
const qreg = ra8.chip.core.cpu.mve.qreg;
const vpt = ra8.chip.core.cpu.mve.vpt;
const decode = ra8.chip.core.cpu.decode;

fn wide(hw1: u16, hw2: u16) Instr {
    return .{ .address = 0, .hw1 = hw1, .hw2 = hw2, .size = 4 };
}

fn run(cpu: *Cpu, hw1: u16, hw2: u16) !void {
    const instr = wide(hw1, hw2);
    const exec = reduce.group.decode(instr) orelse return error.NotClaimed;
    try exec(cpu, instr);
}

const bytes: u128 = 0x0101_0101_0101_0101_0101_0101_0101_01FF;

test "vaddva.u8 r2, q0 adds every byte to r2" {
    var cpu: Cpu = .{ .bus = undefined };
    qreg.write(&cpu.fp.bank, 0, bytes);
    cpu.regs.set(2, 1000);
    try run(&cpu, 0xFEF1, 0x2F20);
    try std.testing.expectEqual(@as(u32, 1000 + 255 + 15), cpu.regs.get(2));
}

test "vmlav.u16 r0, q0, q0 sums the squares" {
    var cpu: Cpu = .{ .bus = undefined };
    qreg.write(&cpu.fp.bank, 0, 0x0000_0000_0000_0000_0000_0000_0003_0002);
    cpu.regs.set(0, 99);
    try run(&cpu, 0xFEF0, 0x0E00);
    try std.testing.expectEqual(@as(u32, 13), cpu.regs.get(0));
}

test "vmlalva.s32 r0, r1 accumulates into the pair" {
    var cpu: Cpu = .{ .bus = undefined };
    qreg.write(&cpu.fp.bank, 1, 0xFFFF_FFFF);
    qreg.write(&cpu.fp.bank, 2, 1);
    cpu.regs.set(0, 0);
    cpu.regs.set(1, 1);
    try run(&cpu, 0xEE83, 0x0E24);
    try std.testing.expectEqual(@as(u32, 0xFFFF_FFFF), cpu.regs.get(0));
    try std.testing.expectEqual(@as(u32, 0), cpu.regs.get(1));
}

test "inside a VPT block only active elements count and the block advances" {
    var cpu: Cpu = .{ .bus = undefined };
    qreg.write(&cpu.fp.bank, 0, bytes);
    cpu.fp.vpr = vpt.open(.{ .p0 = 0x0003 }, 0b1000);
    try run(&cpu, 0xFEF1, 0x0F00);
    try std.testing.expectEqual(@as(u32, 256), cpu.regs.get(0));
    try std.testing.expect(!vpt.inBlock(cpu.fp.vpr));
}

test "activeOnly clears the inactive elements" {
    try std.testing.expectEqual(@as(u128, 0xFFFF_0000), reduce.activeOnly(0xFFFF_FFFF, .half, 0x000C));
}

test "the table routes every form here" {
    const forms = [_][2]u16{
        .{ 0xEEF1, 0x0F00 }, .{ 0xFEF9, 0x2F20 }, .{ 0xEE89, 0x0F00 }, .{ 0xEEF0, 0x0F00 },
        .{ 0xEEF1, 0x0E00 }, .{ 0xEEF2, 0x1E05 }, .{ 0xFEF2, 0x0E25 }, .{ 0xEE82, 0x0E04 },
        .{ 0xFE83, 0x0E04 }, .{ 0xEED3, 0xDE25 },
    };
    for (forms) |e| {
        const hit = decode.decode(wide(e[0], e[1])) orelse return error.NotClaimed;
        try std.testing.expectEqualStrings("mve_reduce", hit.group);
    }
}

test "unclaimed: u with x, vaddv size 11, rdahi of sp" {
    try std.testing.expect(reduce.group.decode(wide(0xFEF4, 0x1E02)) == null);
    try std.testing.expect(reduce.group.decode(wide(0xEEFD, 0x0F02)) == null);
    try std.testing.expect(reduce.group.decode(wide(0xEEE4, 0x0E02)) == null);
}
