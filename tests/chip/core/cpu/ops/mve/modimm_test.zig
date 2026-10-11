//! Covers src/chip/core/cpu/ops/mve_modimm.zig. The encodings come from LLVM's
//! assembler for -mcpu=cortex-m85 with MVE.
const std = @import("std");
const ra8 = @import("ra8");
const Cpu = ra8.chip.core.cpu.cpu.Cpu;
const Instr = ra8.chip.core.cpu.instr.Instr;
const mve_modimm = ra8.chip.core.cpu.ops.mve.modimm;
const qreg = ra8.chip.core.cpu.mve.qreg;

fn wide(hw1: u16, hw2: u16) Instr {
    return .{ .address = 0, .hw1 = hw1, .hw2 = hw2, .size = 4 };
}

fn run(cpu: *Cpu, hw1: u16, hw2: u16) !void {
    const instr = wide(hw1, hw2);
    const exec = mve_modimm.group.decode(instr) orelse return error.NotClaimed;
    try exec(cpu, instr);
}

test "fields splits imm8 across i, imm3 and imm4" {
    const f = mve_modimm.fields(wide(0xFF83, 0x665E)).?;
    try std.testing.expectEqual(@as(u3, 3), f.qd);
    try std.testing.expectEqual(@as(u4, 6), f.cmode);
    try std.testing.expectEqual(@as(u1, 0), f.op);
    try std.testing.expectEqual(@as(u8, 0xBE), f.imm8);
}

test "vmov.f32 q0, #-3.0 fills every lane" {
    var cpu: Cpu = .{ .bus = undefined };
    try run(&cpu, 0xFF80, 0x0F58);
    try std.testing.expectEqual(@as(u128, 0xC0400000_C0400000_C0400000_C0400000), qreg.read(&cpu.fp.bank, 0));
}

test "vorr.i32 q3, #0xf keeps the other bits" {
    var cpu: Cpu = .{ .bus = undefined };
    qreg.write(&cpu.fp.bank, 3, 0xF0);
    try run(&cpu, 0xEF80, 0x615F);
    try std.testing.expectEqual(@as(u128, 0xF_0000000F_0000000F_000000FF), qreg.read(&cpu.fp.bank, 3));
}

test "cmode 1111 with op set and D set are not claimed" {
    try std.testing.expect(mve_modimm.group.decode(wide(0xFF80, 0x0F78)) == null);
    try std.testing.expect(mve_modimm.group.decode(wide(0xFFC2, 0x005B)) == null);
}
