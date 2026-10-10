//! Covers src/chip/core/cpu/ops/mve_widen.zig. The encodings come from LLVM's
//! assembler for -mcpu=cortex-m85 with MVE.
const std = @import("std");
const ra8 = @import("ra8");
const Cpu = ra8.chip.core.cpu.cpu.Cpu;
const Instr = ra8.chip.core.cpu.instr.Instr;
const mve_widen = ra8.chip.core.cpu.ops.mve_widen;
const qreg = ra8.chip.core.cpu.mve.qreg;

fn wide(hw1: u16, hw2: u16) Instr {
    return .{ .address = 0, .hw1 = hw1, .hw2 = hw2, .size = 4 };
}

test "T1 imm5 picks the source size and the shift" {
    const b = mve_widen.fields(wide(0xEEAB, 0x2F44)).?;
    try std.testing.expectEqual(qreg.Size.byte, b.size);
    try std.testing.expectEqual(@as(u6, 3), b.left);
    try std.testing.expectEqual(@as(u3, 1), b.qd);
    try std.testing.expectEqual(@as(u3, 2), b.qm);
    const h = mve_widen.fields(wide(0xFEB5, 0x3F44)).?;
    try std.testing.expectEqual(qreg.Size.half, h.size);
    try std.testing.expectEqual(@as(u6, 5), h.left);
    try std.testing.expect(h.unsigned);
}

test "T2 shifts by the source width" {
    try std.testing.expectEqual(@as(u6, 8), mve_widen.fields(wide(0xEE31, 0x2E05)).?.left);
    try std.testing.expectEqual(@as(u6, 16), mve_widen.fields(wide(0xFE35, 0x3E05)).?.left);
}

test "vmovlb.s16 q0, q0 widens in place" {
    var cpu: Cpu = .{ .bus = undefined };
    qreg.write(&cpu.fp.bank, 0, 0x0000_8000_0000_7FFF);
    const instr = wide(0xEEB0, 0x0F40);
    try (mve_widen.group.decode(instr).?)(&cpu, instr);
    try std.testing.expectEqual(@as(u128, 0xFFFF8000_00007FFF), qreg.read(&cpu.fp.bank, 0));
}

test "VMOVN's space and imm5 00xxx are not claimed" {
    try std.testing.expect(mve_widen.group.decode(wide(0xEE31, 0x2E85)) == null);
    try std.testing.expect(mve_widen.group.decode(wide(0xEEA4, 0x2F44)) == null);
}
