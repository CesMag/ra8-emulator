//! Covers src/chip/core/cpu/ops/mve_int_vmla.zig. The encodings come from
//! LLVM's assembler for -mcpu=cortex-m85 with MVE.
const std = @import("std");
const ra8 = @import("ra8");
const Cpu = ra8.chip.core.cpu.cpu.Cpu;
const Instr = ra8.chip.core.cpu.instr.Instr;
const vmla = ra8.chip.core.cpu.ops.mve_int_vmla;
const qreg = ra8.chip.core.cpu.mve.qreg;
const decode = ra8.chip.core.cpu.decode;

fn wide(hw1: u16, hw2: u16) Instr {
    return .{ .address = 0, .hw1 = hw1, .hw2 = hw2, .size = 4 };
}

fn run(cpu: *Cpu, hw1: u16, hw2: u16) !void {
    const instr = wide(hw1, hw2);
    const exec = vmla.group.decode(instr) orelse return error.NotClaimed;
    try exec(cpu, instr);
}

/// Q0 accumulates, Q1 is the vector and R2 the scalar for `op q0, q1, r2`.
fn loaded(da: u128, n: u128, scalar: u32) Cpu {
    var cpu: Cpu = .{ .bus = undefined };
    qreg.write(&cpu.fp.bank, 0, da);
    qreg.write(&cpu.fp.bank, 1, n);
    cpu.regs.set(2, scalar);
    return cpu;
}

fn q0(cpu: *const Cpu) u128 {
    return qreg.read(&cpu.fp.bank, 0);
}

test "vmla.i8 adds the vector times the scalar into Qda" {
    var cpu = loaded(0xFF_01, 0x01_03, 0x1_02);
    try run(&cpu, 0xEE03, 0x0E42);
    try std.testing.expectEqual(@as(u128, 0x01_07), q0(&cpu));
}

test "vmlas.i16 multiplies Qda by the vector and adds the scalar to every lane" {
    var cpu = loaded(0x0001_0002, 0x0003_0003, 0x5);
    try run(&cpu, 0xEE13, 0x1E42);
    try std.testing.expectEqual(@as(u128, 0x0005_0005_0005_0005_0005_0005_0008_000B), q0(&cpu));
}

test "vmla.i32 q0, q7, r12 takes Qn from hw1 and Rm from hw2" {
    var cpu: Cpu = .{ .bus = undefined };
    qreg.write(&cpu.fp.bank, 7, 0x2);
    cpu.regs.set(12, 0x10);
    try run(&cpu, 0xEE2F, 0x0E4C);
    try std.testing.expectEqual(@as(u128, 0x20), q0(&cpu));
}

test "a masked-off lane keeps its accumulator" {
    var cpu = loaded(0x11_11, 0x01_01, 0x1);
    cpu.fp.vpr = ra8.chip.core.cpu.mve.vpt.open(.{ .p0 = 0xFFFD }, 0b1000);
    try run(&cpu, 0xEE03, 0x0E42);
    try std.testing.expectEqual(@as(u128, 0x11_12), q0(&cpu) & 0xFFFF);
}

test "the table routes the T1 encodings here" {
    for ([_][2]u16{ .{ 0xEE03, 0x0E42 }, .{ 0xEE23, 0x1E42 }, .{ 0xEE2F, 0x1E4E } }) |e| {
        const hit = decode.decode(wide(e[0], e[1])) orelse return error.NotClaimed;
        try std.testing.expectEqualStrings("mve_int_vmla", hit.group);
    }
}

test "unclaimed: size 3, Rm SP or PC, the VMULH tail" {
    try std.testing.expect(vmla.group.decode(wide(0xEE33, 0x0E42)) == null);
    try std.testing.expect(vmla.group.decode(wide(0xEE03, 0x0E4D)) == null);
    try std.testing.expect(vmla.group.decode(wide(0xEE03, 0x0E4F)) == null);
    try std.testing.expect(vmla.group.decode(wide(0xEE03, 0x0E05)) == null);
}
