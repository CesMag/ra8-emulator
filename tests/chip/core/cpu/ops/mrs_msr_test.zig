//! Covers src/chip/core/cpu/ops/mrs_msr.zig.
const std = @import("std");
const ra8 = @import("ra8");
const Cpu = ra8.chip.core.cpu.cpu.Cpu;
const Instr = ra8.chip.core.cpu.instr.Instr;
const regs = ra8.chip.core.cpu.regs;
const mrs_msr = ra8.chip.core.cpu.ops.mrs_msr;
const branch_wide = ra8.chip.core.cpu.ops.branch.wide;

fn wide(hw1: u16, hw2: u16) Instr {
    return .{ .address = 0, .hw1 = hw1, .hw2 = hw2, .size = 4 };
}

fn run(cpu: *Cpu, hw1: u16, hw2: u16) !void {
    const exec = mrs_msr.group.decode(wide(hw1, hw2)) orelse return error.NotClaimed;
    try exec(cpu, wide(hw1, hw2));
}

fn fresh() Cpu {
    return .{ .bus = undefined, .regs = .{ .xpsr = regs.xpsr_bits.thumb } };
}

test "mrs r0, ipsr is the blink_hal encoding" {
    var cpu = fresh();
    cpu.regs.xpsr |= 0x2F;
    cpu.regs.low[0] = 0xDEAD;
    try run(&cpu, 0xF3EF, 0x8005);
    try std.testing.expectEqual(@as(u32, 0x2F), cpu.regs.low[0]);
}

test "msr primask, r1 then mrs r2, primask round-trips" {
    var cpu = fresh();
    cpu.regs.low[1] = 1;
    try run(&cpu, 0xF381, 0x8810);
    try std.testing.expectEqual(@as(u32, 1), cpu.regs.primask);
    try run(&cpu, 0xF3EF, 0x8210);
    try std.testing.expectEqual(@as(u32, 1), cpu.regs.low[2]);
}

test "msr apsr_nzcvq and apsr_g write their own bits" {
    var cpu = fresh();
    cpu.regs.low[3] = 0xFFFF_FFFF;
    try run(&cpu, 0xF383, 0x8800); // msr apsr_nzcvq, r3
    try std.testing.expectEqual(0xF800_0000 | regs.xpsr_bits.thumb, cpu.regs.xpsr);
    try run(&cpu, 0xF383, 0x8400); // msr apsr_g, r3
    try std.testing.expectEqual(@as(u32, 0x000F_0000), cpu.regs.xpsr & 0x000F_0000);
}

test "unclaimed: SP or PC operands, mask 00, a non-10 mask off xPSR" {
    try std.testing.expect(mrs_msr.group.decode(wide(0xF3EF, 0x8D05)) == null);
    try std.testing.expect(mrs_msr.group.decode(wide(0xF38D, 0x8810)) == null);
    try std.testing.expect(mrs_msr.group.decode(wide(0xF381, 0x8010)) == null);
    try std.testing.expect(mrs_msr.group.decode(wide(0xF381, 0x8C10)) == null);
}

test "branch_wide does not claim these encodings first" {
    try std.testing.expect(branch_wide.group.decode(wide(0xF3EF, 0x8005)) == null);
    try std.testing.expect(branch_wide.group.decode(wide(0xF381, 0x8810)) == null);
}

test "msr psplim, r12 is the ThreadX scheduler encoding and mrs reads it back" {
    var cpu = fresh();
    cpu.regs.low[12] = 0x2201_0204;
    try run(&cpu, 0xF38C, 0x880B); // msr psplim, r12
    try std.testing.expectEqual(@as(u32, 0x2201_0200), cpu.regs.psplim);
    try run(&cpu, 0xF3EF, 0x800B); // mrs r0, psplim
    try std.testing.expectEqual(@as(u32, 0x2201_0200), cpu.regs.low[0]);
    try run(&cpu, 0xF3EF, 0x810A); // mrs r1, msplim
    try std.testing.expectEqual(@as(u32, 0), cpu.regs.low[1]);
}

test "msr msp_ns, r2 from Secure reaches the Non-secure bank, the cpu1_pingpong_ipc encoding" {
    var cpu = fresh();
    cpu.regs.low[2] = 0x2210_0403;
    try run(&cpu, 0xF382, 0x8888); // msr msp_ns, r2
    try std.testing.expectEqual(@as(u32, 0x2210_0400), cpu.banked.other.msp);
    try std.testing.expectEqual(@as(u32, 0), cpu.regs.msp);
    try run(&cpu, 0xF3EF, 0x8388); // mrs r3, msp_ns
    try std.testing.expectEqual(@as(u32, 0x2210_0400), cpu.regs.low[3]);
}

test "the _NS forms are privileged only and Non-secure state reads zero" {
    var cpu = fresh();
    cpu.regs.control = regs.control_bits.npriv;
    cpu.regs.low[2] = 0x2210_0400;
    try run(&cpu, 0xF382, 0x8888);
    try std.testing.expectEqual(@as(u32, 0), cpu.banked.other.msp);
    cpu.regs.control = 0;
    cpu.banked.other.psp = 0x1234_5678;
    cpu.banked.current = .non_secure;
    cpu.regs.low[0] = 0xFFFF;
    try run(&cpu, 0xF3EF, 0x8089); // mrs r0, psp_ns
    try std.testing.expectEqual(@as(u32, 0), cpu.regs.low[0]);
}

test "nsAlias names the banked.zig codes and nothing between them" {
    try std.testing.expect(mrs_msr.nsAlias(0x88) and mrs_msr.nsAlias(0x94) and mrs_msr.nsAlias(0x98));
    try std.testing.expect(!mrs_msr.nsAlias(0x8C) and !mrs_msr.nsAlias(0x92) and !mrs_msr.nsAlias(0x99));
    try std.testing.expect(mrs_msr.group.decode(wide(0xF3EF, 0x808C)) == null);
    try std.testing.expect(mrs_msr.group.decode(wide(0xF382, 0x8488)) == null); // mask 01
}

test "M33 CONTROL reads zero for PACBTI enables and ignores writes to them" {
    var cpu = fresh();
    cpu.profile = ra8.chip.core.cpu.decode.profile.Profile.m33;
    const enables = regs.control_bits.bti_en | regs.control_bits.ubti_en |
        regs.control_bits.pac_en | regs.control_bits.upac_en;
    cpu.regs.low[1] = enables;
    try run(&cpu, 0xF381, 0x8814); // msr control, r1
    try std.testing.expectEqual(@as(u32, 0), cpu.regs.control & enables);
    try run(&cpu, 0xF3EF, 0x8014); // mrs r0, control
    try std.testing.expectEqual(@as(u32, 0), cpu.regs.low[0] & enables);
}
