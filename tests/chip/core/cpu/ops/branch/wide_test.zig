//! Covers src/chip/core/cpu/ops/branch_wide.zig.
const std = @import("std");
const ra8 = @import("ra8");
const Cpu = ra8.chip.core.cpu.cpu.Cpu;
const Instr = ra8.chip.core.cpu.instr.Instr;
const regs = ra8.chip.core.cpu.regs;
const bits = ra8.chip.core.cpu.flags.bits;
const branch_wide = ra8.chip.core.cpu.ops.branch.wide;

fn at(address: u32, hw1: u16, hw2: u16) Instr {
    return .{ .address = address, .hw1 = hw1, .hw2 = hw2, .size = 4 };
}

fn run(cpu: *Cpu, instr: Instr) !void {
    const exec = branch_wide.group.decode(instr) orelse return error.NotClaimed;
    cpu.regs.pc = instr.address +% 4;
    try exec(cpu, instr);
}

fn fresh(nzcv: u32) Cpu {
    return .{ .bus = undefined, .regs = .{ .xpsr = regs.xpsr_bits.thumb | nzcv } };
}

test "bl forward sets lr to the return address with the thumb bit" {
    var cpu = fresh(0);
    try run(&cpu, at(0x0200_2F82, 0xF000, 0xF933));
    try std.testing.expectEqual(@as(u32, 0x0200_2F86 + 0x266), cpu.regs.pc);
    try std.testing.expectEqual(@as(u32, 0x0200_2F87), cpu.regs.lr);
}

test "bl backward sign-extends through S, I1 and I2" {
    // bl .-0x1000 at 0x2000: S=1, J1=J2=1 (I1=I2=1), imm10=0x3FF, imm11=0x7FE.
    var cpu = fresh(0);
    try run(&cpu, at(0x2000, 0xF7FF, 0xFFFE));
    try std.testing.expectEqual(@as(i32, -4), branch_wide.offset24(at(0, 0xF7FF, 0xFFFE)));
    try std.testing.expectEqual(@as(u32, 0x2000), cpu.regs.pc);
    try std.testing.expectEqual(@as(i32, 0x00FF_FFFE), branch_wide.offset24(at(0, 0xF3FF, 0xD7FF)));
    try std.testing.expectEqual(@as(i32, -0x0100_0000), branch_wide.offset24(at(0, 0xF400, 0xD000)));
}

test "b.w jumps without touching lr" {
    var cpu = fresh(0);
    cpu.regs.lr = 0x1234;
    try run(&cpu, at(0x1000, 0xF000, 0xB800));
    try std.testing.expectEqual(@as(u32, 0x1004), cpu.regs.pc);
    try std.testing.expectEqual(@as(u32, 0x1234), cpu.regs.lr);
}

test "beq.w follows Z" {
    // beq.w .+0x104: cond 0000, imm6 0, imm11 0x80.
    var taken = fresh(bits.z);
    try run(&taken, at(0x1000, 0xF000, 0x8080));
    try std.testing.expectEqual(@as(u32, 0x1104), taken.regs.pc);
    var not_taken = fresh(0);
    try run(&not_taken, at(0x1000, 0xF000, 0x8080));
    try std.testing.expectEqual(@as(u32, 0x1004), not_taken.regs.pc);
    try std.testing.expectEqual(@as(i32, -2), branch_wide.offset20(at(0, 0xF43F, 0xAFFF)));
}

test "the miscellaneous control space and non-branches are not claimed" {
    try std.testing.expect(branch_wide.group.decode(at(0, 0xF3BF, 0x8F4F)) == null);
    try std.testing.expect(branch_wide.group.decode(at(0, 0xF3EF, 0x8008)) == null);
    try std.testing.expect(branch_wide.group.decode(at(0, 0xF44F, 0x4225)) == null);
    try std.testing.expect(branch_wide.group.decode(at(0, 0xF000, 0xC000)) == null);
}
