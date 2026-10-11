//! Covers src/chip/core/cpu/ops/mve_int.zig. The encodings come from LLVM's
//! assembler for -mcpu=cortex-m85 with MVE.
const std = @import("std");
const ra8 = @import("ra8");
const Cpu = ra8.chip.core.cpu.cpu.Cpu;
const Instr = ra8.chip.core.cpu.instr.Instr;
const mve_int = ra8.chip.core.cpu.ops.mve.int;
const qreg = ra8.chip.core.cpu.mve.qreg;
const decode = ra8.chip.core.cpu.decode;

fn wide(hw1: u16, hw2: u16) Instr {
    return .{ .address = 0, .hw1 = hw1, .hw2 = hw2, .size = 4 };
}

fn run(cpu: *Cpu, hw1: u16, hw2: u16) !void {
    const instr = wide(hw1, hw2);
    const exec = mve_int.group.decode(instr) orelse return error.NotClaimed;
    try exec(cpu, instr);
}

fn loaded() Cpu {
    var cpu: Cpu = .{ .bus = undefined };
    qreg.write(&cpu.fp.bank, 1, 0x0000_0004_0000_0003_0000_0002_FFFF_FFFF);
    qreg.write(&cpu.fp.bank, 2, 0x0000_0010_0000_0010_0000_0010_0000_0002);
    return cpu;
}

test "vadd.i32, vsub.i32 and vmul.i32 q0, q1, q2" {
    var cpu = loaded();
    try run(&cpu, 0xEF22, 0x0844);
    try std.testing.expectEqual(@as(u128, 0x0000_0014_0000_0013_0000_0012_0000_0001), qreg.read(&cpu.fp.bank, 0));
    try run(&cpu, 0xFF22, 0x0844);
    try std.testing.expectEqual(@as(u128, 0xFFFF_FFF4_FFFF_FFF3_FFFF_FFF2_FFFF_FFFD), qreg.read(&cpu.fp.bank, 0));
    try run(&cpu, 0xEF22, 0x0954);
    try std.testing.expectEqual(@as(u128, 0x0000_0040_0000_0030_0000_0020_FFFF_FFFE), qreg.read(&cpu.fp.bank, 0));
}

test "vadd.i8 wraps each byte lane" {
    var cpu = loaded();
    try run(&cpu, 0xEF02, 0x0844);
    try std.testing.expectEqual(@as(u128, 0x0000_0014_0000_0013_0000_0012_FFFF_FF01), qreg.read(&cpu.fp.bank, 0));
}

test "register fields: vadd.i32 q7, q0, q0 / q0, q7, q0 / q0, q0, q7" {
    try std.testing.expectEqual([3]u3{ 7, 0, 0 }, mve_int.regs(wide(0xEF20, 0xE840)));
    try std.testing.expectEqual([3]u3{ 0, 7, 0 }, mve_int.regs(wide(0xEF2E, 0x0840)));
    try std.testing.expectEqual([3]u3{ 0, 0, 7 }, mve_int.regs(wide(0xEF20, 0x084E)));
}

test "inside vpste the first add writes P0 lanes and the second the rest" {
    var cpu = loaded();
    cpu.fp.vpr = ra8.chip.core.cpu.mve.vpt.open(.{ .p0 = 0x00FF }, 0b1100);
    try run(&cpu, 0xEF22, 0x0844);
    try std.testing.expectEqual(@as(u128, 0x0000_0000_0000_0000_0000_0012_0000_0001), qreg.read(&cpu.fp.bank, 0));
    try run(&cpu, 0xFF22, 0x0844);
    try std.testing.expectEqual(@as(u128, 0xFFFF_FFF4_FFFF_FFF3_0000_0012_0000_0001), qreg.read(&cpu.fp.bank, 0));
    try std.testing.expect(!ra8.chip.core.cpu.mve.vpt.inBlock(cpu.fp.vpr));
}

test "the table routes the T1 encodings here" {
    for ([_][2]u16{ .{ 0xEF12, 0x0844 }, .{ 0xFF02, 0x0844 }, .{ 0xEF22, 0x0954 } }) |e| {
        const hit = decode.decode(wide(e[0], e[1])) orelse return error.NotClaimed;
        try std.testing.expectEqualStrings("mve_int", hit.group);
    }
}

test "unclaimed: size 3, D/N/M set, VMUL with U, other hw2" {
    try std.testing.expect(mve_int.group.decode(wide(0xEF32, 0x0844)) == null);
    try std.testing.expect(mve_int.group.decode(wide(0xEF62, 0x0844)) == null);
    try std.testing.expect(mve_int.group.decode(wide(0xEF22, 0x08C4)) == null);
    try std.testing.expect(mve_int.group.decode(wide(0xEF22, 0x0864)) == null);
    try std.testing.expect(mve_int.group.decode(wide(0xFF22, 0x0954)) == null);
    try std.testing.expect(mve_int.group.decode(wide(0xEF22, 0x0845)) == null);
}
