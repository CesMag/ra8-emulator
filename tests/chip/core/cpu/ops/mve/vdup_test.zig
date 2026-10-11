//! Covers src/chip/core/cpu/ops/mve_vdup.zig. The encodings come from LLVM's
//! assembler for -mcpu=cortex-m85 with MVE.
const std = @import("std");
const ra8 = @import("ra8");
const Cpu = ra8.chip.core.cpu.cpu.Cpu;
const Instr = ra8.chip.core.cpu.instr.Instr;
const vdup = ra8.chip.core.cpu.ops.mve.vdup;
const qreg = ra8.chip.core.cpu.mve.qreg;
const vpt = ra8.chip.core.cpu.mve.vpt;
const decode = ra8.chip.core.cpu.decode;
const it_state = ra8.chip.core.cpu.it_state;

fn wide(hw1: u16, hw2: u16) Instr {
    return .{ .address = 0, .hw1 = hw1, .hw2 = hw2, .size = 4 };
}

fn run(cpu: *Cpu, hw1: u16, hw2: u16) !void {
    const instr = wide(hw1, hw2);
    const exec = vdup.group.decode(instr) orelse return error.NotClaimed;
    try exec(cpu, instr);
}

test "vdup.32 q0, r1 fills every word" {
    var cpu: Cpu = .{ .bus = undefined };
    cpu.regs.set(1, 0xDEAD_BEEF);
    try run(&cpu, 0xEEA0, 0x1B10);
    try std.testing.expectEqual(@as(u128, 0xDEADBEEF_DEADBEEF_DEADBEEF_DEADBEEF), qreg.read(&cpu.fp.bank, 0));
}

test "vdup.16 and vdup.8 keep only the low bits" {
    var cpu: Cpu = .{ .bus = undefined };
    cpu.regs.set(1, 0x1234_5678);
    try run(&cpu, 0xEEA0, 0x1B30);
    try std.testing.expectEqual(@as(u128, 0x5678_5678_5678_5678_5678_5678_5678_5678), qreg.read(&cpu.fp.bank, 0));
    try run(&cpu, 0xEEE4, 0x1B10);
    try std.testing.expectEqual(@as(u128, 0x7878_7878_7878_7878_7878_7878_7878_7878), qreg.read(&cpu.fp.bank, 2));
}

test "vdup.32 q7, r12 reads both register fields" {
    var cpu: Cpu = .{ .bus = undefined };
    cpu.regs.set(12, 5);
    try run(&cpu, 0xEEAE, 0xCB10);
    try std.testing.expectEqual(@as(u32, 5), qreg.elem(qreg.read(&cpu.fp.bank, 7), .word, 3));
}

test "vdup inside a VPT block writes only the active lanes and advances" {
    var cpu: Cpu = .{ .bus = undefined };
    cpu.regs.set(1, 0xFFFF_FFFF);
    cpu.fp.vpr = vpt.open(.{ .p0 = 0x00F0 }, 0b1000);
    try run(&cpu, 0xEEA0, 0x1B10);
    try std.testing.expectEqual(@as(u128, 0xFFFF_FFFF) << 32, qreg.read(&cpu.fp.bank, 0));
    try std.testing.expect(!vpt.inBlock(cpu.fp.vpr));
}

test "vdup resumes after beat A0 and clears ECI" {
    var cpu: Cpu = .{ .bus = undefined };
    cpu.regs.set(1, 0xFFFF_FFFF);
    cpu.regs.xpsr = it_state.put(cpu.regs.xpsr, 0x10);
    try run(&cpu, 0xEEA0, 0x1B10);
    try std.testing.expectEqual(
        @as(u128, 0xFFFF_FFFF_FFFF_FFFF_FFFF_FFFF_0000_0000),
        qreg.read(&cpu.fp.bank, 0),
    );
    try std.testing.expectEqual(@as(u8, 0), it_state.get(cpu.regs.xpsr));
}

test "the table routes VDUP here" {
    const hit = decode.decode(wide(0xEEE0, 0x1B10)) orelse return error.NotClaimed;
    try std.testing.expectEqualStrings("mve_vdup", hit.group);
}

test "unclaimed: B:E of 11, Rt of 13 and 15" {
    try std.testing.expect(vdup.group.decode(wide(0xEEE0, 0x1B30)) == null);
    try std.testing.expect(vdup.group.decode(wide(0xEEA0, 0xDB10)) == null);
    try std.testing.expect(vdup.group.decode(wide(0xEEA0, 0xFB10)) == null);
}
