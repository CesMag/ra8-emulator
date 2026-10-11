//! Covers src/chip/core/cpu/ops/imm_fields.zig.
const std = @import("std");
const ra8 = @import("ra8");
const Fields = ra8.chip.core.cpu.ops.imm.fields.Fields;
const Instr = ra8.chip.core.cpu.instr.Instr;

fn wide(hw1: u16, hw2: u16) Instr {
    return .{ .address = 0, .hw1 = hw1, .hw2 = hw2, .size = 4 };
}

test "mov.w r2, #0xa500 splits into its fields" {
    const f = Fields.of(wide(0xF44F, 0x4225)).?;
    try std.testing.expectEqual(@as(u4, 0b0010), f.opcode);
    try std.testing.expect(!f.s);
    try std.testing.expectEqual(@as(u4, 15), f.rn);
    try std.testing.expectEqual(@as(u4, 2), f.rd);
}

test "neighbouring classes are not modified immediates" {
    try std.testing.expect(Fields.of(wide(0xF240, 0x0000)) == null);
    try std.testing.expect(Fields.of(wide(0xF000, 0xF800)) == null);
    try std.testing.expect(Fields.of(.{ .address = 0, .hw1 = 0xF44F, .hw2 = 0, .size = 2 }) == null);
}
