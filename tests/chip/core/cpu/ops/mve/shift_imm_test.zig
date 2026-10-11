//! Covers src/chip/core/cpu/ops/mve_shift_imm.zig. The encodings come from
//! LLVM's assembler for cortex-m85; the values each form computes are the
//! conformance vectors' job, so this file checks the decoded fields.
const std = @import("std");
const ra8 = @import("ra8");
const Instr = ra8.chip.core.cpu.instr.Instr;
const mve_shift_imm = ra8.chip.core.cpu.ops.mve.shift_imm;

fn wide(hw1: u16, hw2: u16) Instr {
    return .{ .address = 0x100, .hw1 = hw1, .hw2 = hw2, .size = 4 };
}

fn expectFields(hw1: u16, hw2: u16, kind: mve_shift_imm.Kind, size: ra8.chip.core.cpu.mve.qreg.Size, amount: u6) !void {
    const f = mve_shift_imm.fields(wide(hw1, hw2)) orelse return error.NotClaimed;
    try std.testing.expectEqual(kind, f.kind);
    try std.testing.expectEqual(size, f.size);
    try std.testing.expectEqual(amount, f.amount);
}

test "right shifts count down from twice the lane width" {
    try expectFields(0xFFB1, 0x0050, .vshr, .word, 15);
    try expectFields(0xEF8F, 0x2054, .vshr, .byte, 1);
    try expectFields(0xFF88, 0x2254, .vrshr, .byte, 8);
    try expectFields(0xFFA0, 0x2454, .vsri, .word, 32);
}

test "left shifts count up from the lane width" {
    try expectFields(0xEF95, 0x2554, .vshl, .half, 5);
    try expectFields(0xFF94, 0x2554, .vsli, .half, 4);
    try expectFields(0xEF8B, 0x2754, .vqshl, .byte, 3);
    try expectFields(0xFFA2, 0x2654, .vqshlu, .word, 2);
}

test "registers and signedness" {
    const f = mve_shift_imm.fields(wide(0xFF94, 0xE75C)).?;
    try std.testing.expectEqual(@as(u3, 7), f.qd);
    try std.testing.expectEqual(@as(u3, 6), f.qm);
    try std.testing.expect(f.unsigned);
}

test "the modified-immediate space is left alone" {
    try std.testing.expect(mve_shift_imm.group.decode(wide(0xEF87, 0x2054)) == null);
    try std.testing.expect(mve_shift_imm.group.decode(wide(0xEF80, 0x0F78)) == null);
}
