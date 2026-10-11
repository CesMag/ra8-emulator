//! Covers src/chip/core/cpu/ops/mve_lane_pair.zig. The encodings come from
//! LLVM's assembler for -mcpu=cortex-m85 with MVE.
const std = @import("std");
const ra8 = @import("ra8");
const Cpu = ra8.chip.core.cpu.cpu.Cpu;
const Instr = ra8.chip.core.cpu.instr.Instr;
const lane_pair = ra8.chip.core.cpu.ops.mve_lane_pair;
const qreg = ra8.chip.core.cpu.mve.qreg;
const vpt = ra8.chip.core.cpu.mve.vpt;
const decode = ra8.chip.core.cpu.decode;

fn wide(hw1: u16, hw2: u16) Instr {
    return .{ .address = 0, .hw1 = hw1, .hw2 = hw2, .size = 4 };
}

fn run(cpu: *Cpu, hw1: u16, hw2: u16) !void {
    const instr = wide(hw1, hw2);
    const exec = lane_pair.group.decode(instr) orelse return error.NotClaimed;
    try exec(cpu, instr);
}

const lanes: u128 = 0x44444444_33333333_22222222_11111111;

test "vmov q0[2], q0[0], r1, r2 writes words 2 and 0 only" {
    var cpu: Cpu = .{ .bus = undefined };
    qreg.write(&cpu.fp.bank, 0, lanes);
    cpu.regs.set(1, 0xAAAA_AAAA);
    cpu.regs.set(2, 0xBBBB_BBBB);
    try run(&cpu, 0xEC12, 0x0F01);
    try std.testing.expectEqual(@as(u128, 0x44444444_AAAAAAAA_22222222_BBBBBBBB), qreg.read(&cpu.fp.bank, 0));
}

test "vmov q7[3], q7[1] through the index bit and Qd field" {
    var cpu: Cpu = .{ .bus = undefined };
    cpu.regs.set(12, 0xC);
    cpu.regs.set(11, 0xB);
    try run(&cpu, 0xEC1B, 0xEF1C);
    try std.testing.expectEqual(@as(u128, 0xC_00000000_0000000B_00000000), qreg.read(&cpu.fp.bank, 7));
}

test "vmov r1, r11, q5[2], q5[0] reads the pair" {
    var cpu: Cpu = .{ .bus = undefined };
    qreg.write(&cpu.fp.bank, 5, lanes);
    try run(&cpu, 0xEC0B, 0xAF01);
    try std.testing.expectEqual(@as(u32, 0x3333_3333), cpu.regs.get(1));
    try std.testing.expectEqual(@as(u32, 0x1111_1111), cpu.regs.get(11));
}

test "vmov r12, r2, q0[3], q0[1] leaves VPT alone" {
    var cpu: Cpu = .{ .bus = undefined };
    qreg.write(&cpu.fp.bank, 0, lanes);
    cpu.fp.vpr = vpt.open(.{ .p0 = 0 }, 0b1000);
    const before = cpu.fp.vpr;
    try run(&cpu, 0xEC02, 0x0F1C);
    try std.testing.expectEqual(@as(u32, 0x4444_4444), cpu.regs.get(12));
    try std.testing.expectEqual(@as(u32, 0x2222_2222), cpu.regs.get(2));
    try std.testing.expectEqual(before, cpu.fp.vpr);
}

test "the same register twice is fine into the vector" {
    var cpu: Cpu = .{ .bus = undefined };
    cpu.regs.set(1, 7);
    try run(&cpu, 0xEC11, 0x0F01);
    try std.testing.expectEqual(@as(u128, 7 << 64 | 7), qreg.read(&cpu.fp.bank, 0));
}

test "the table routes both directions here" {
    for ([_][2]u16{ .{ 0xEC12, 0x0F01 }, .{ 0xEC02, 0x0F01 }, .{ 0xEC0B, 0xAF01 } }) |e| {
        const hit = decode.decode(wide(e[0], e[1])) orelse return error.NotClaimed;
        try std.testing.expectEqualStrings("mve_lane_pair", hit.group);
    }
}

test "unclaimed: Rt or Rt2 of 13 or 15, a repeated core register, stray bits" {
    try std.testing.expect(lane_pair.group.decode(wide(0xEC1D, 0x0F01)) == null);
    try std.testing.expect(lane_pair.group.decode(wide(0xEC12, 0x0F0F)) == null);
    try std.testing.expect(lane_pair.group.decode(wide(0xEC01, 0x0F01)) == null);
    try std.testing.expect(lane_pair.group.decode(wide(0xEC12, 0x1F01)) == null);
    try std.testing.expect(lane_pair.group.decode(wide(0xEC12, 0x0F21)) == null);
    try std.testing.expect(lane_pair.group.decode(wide(0xEC32, 0x0F01)) == null);
}

test "ECI skips the lane whose beat is done and still moves the other" {
    const it_state = ra8.chip.core.cpu.it_state;
    var cpu: Cpu = .{ .bus = undefined };
    qreg.write(&cpu.fp.bank, 0, lanes);
    cpu.regs.xpsr = it_state.put(0, 0x10);
    cpu.regs.set(1, 0xAAAA_AAAA);
    cpu.regs.set(2, 0xBBBB_BBBB);
    try run(&cpu, 0xEC12, 0x0F01);
    try std.testing.expectEqual(@as(u128, 0x44444444_AAAAAAAA_22222222_11111111), qreg.read(&cpu.fp.bank, 0));
    try std.testing.expectEqual(@as(u8, 0), it_state.get(cpu.regs.xpsr));
}
