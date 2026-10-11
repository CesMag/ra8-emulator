//! Covers src/chip/core/cpu/ops/long_shift.zig.
const std = @import("std");
const ra8 = @import("ra8");
const Cpu = ra8.chip.core.cpu.cpu.Cpu;
const long_shift = ra8.chip.core.cpu.ops.long_shift;

fn wide(hw1: u16, hw2: u16) ra8.chip.core.cpu.instr.Instr {
    return .{ .address = 0, .hw1 = hw1, .hw2 = hw2, .size = 4 };
}

/// Runs the op with r2:r3 = lo:hi and a known xPSR; returns hi:lo.
fn run(hw1: u16, hw2: u16, lo: u32, hi: u32) !u64 {
    var cpu: Cpu = .{ .bus = undefined };
    cpu.regs.low[2] = lo;
    cpu.regs.low[3] = hi;
    cpu.regs.xpsr = 0xF100_0000;
    const exec = long_shift.group.decode(wide(hw1, hw2)) orelse return error.NotClaimed;
    try exec(&cpu, wide(hw1, hw2));
    try std.testing.expectEqual(@as(u32, 0xF100_0000), cpu.regs.xpsr);
    return (@as(u64, cpu.regs.low[3]) << 32) | cpu.regs.low[2];
}

test "lsll r2, r3, #5 from power_profiler (x * 32)" {
    const f = long_shift.fields(wide(0xEA52, 0x134F)).?;
    try std.testing.expectEqual(@as(u4, 2), f.lo);
    try std.testing.expectEqual(@as(u4, 3), f.hi);
    try std.testing.expectEqual(@as(u6, 5), f.amount);
    try std.testing.expectEqual(long_shift.Kind.lsll, f.kind);
    try std.testing.expectEqual(@as(u64, 0x0000_001F_E000_0000), try run(0xEA52, 0x134F, 0xFF00_0000, 0));
}

test "lsrl and asrl r2, r3, #4" {
    // imm3 = 001, imm2 = 00: shift 4; type 01 lsrl, 10 asrl
    try std.testing.expectEqual(@as(u64, 0x0800_0000_0000_0000), try run(0xEA52, 0x131F, 0, 0x8000_0000));
    try std.testing.expectEqual(@as(u64, 0xF800_0000_0000_0000), try run(0xEA52, 0x132F, 0, 0x8000_0000));
}

test "the shift crosses the register boundary" {
    // lsll #31 and lsrl #31
    try std.testing.expectEqual(@as(u64, 0x8000_0000) << 31, try run(0xEA52, 0x73CF, 0x8000_0000, 0));
    try std.testing.expectEqual(@as(u64, 2), try run(0xEA52, 0x73DF, 0, 1));
}

/// Runs the op with r4:r5 = lo:hi; returns hi:lo.
fn runR4(hw2: u16, value: u64) !u64 {
    var cpu: Cpu = .{ .bus = undefined };
    cpu.regs.low[4] = @truncate(value);
    cpu.regs.low[5] = @truncate(value >> 32);
    const exec = long_shift.group.decode(wide(0xEA54, hw2)) orelse return error.NotClaimed;
    try exec(&cpu, wide(0xEA54, hw2));
    return (@as(u64, cpu.regs.low[5]) << 32) | cpu.regs.low[4];
}

test "lsrl and asrl r4, r5, #32 encode the amount as zero (npu_vela_conv)" {
    const f = long_shift.fields(wide(0xEA54, 0x051F)).?;
    try std.testing.expectEqual(@as(u6, 32), f.amount);
    try std.testing.expectEqual(long_shift.Kind.lsrl, f.kind);
    try std.testing.expectEqual(@as(u64, 0x89AB_CDEF), try runR4(0x051F, 0x89AB_CDEF_0123_4567));
    try std.testing.expectEqual(@as(u64, 0xFFFF_FFFF_89AB_CDEF), try runR4(0x052F, 0x89AB_CDEF_0123_4567));
}

test "the forms this slice leaves alone" {
    const left = [_][2]u16{
        .{ 0xEA52, 0x030F }, // lsll of zero
        .{ 0xEA52, 0x1F4F }, // RdaHi 1111: single-register saturating shift
        .{ 0xEA52, 0x137F }, // type 11
        .{ 0xEA53, 0x134F }, // hw1 bit 0 set
        .{ 0xEA52, 0x134E }, // hw2[3:0] not 1111
        .{ 0xEA52, 0x124F }, // hw2 bit 8 clear
        .{ 0xEA42, 0x134F }, // ORR without S
    };
    for (left) |pair| try std.testing.expect(long_shift.group.decode(wide(pair[0], pair[1])) == null);
}

test "the group has a lockstep oracle" {
    try std.testing.expect(long_shift.group.oracle);
}

// Ported from tests/chip/core/long_shift_test.zig (the old seam), run
// against the core's groups (RA8EMU-252). The register, single-register
// saturating and pair saturating cases sit in long_shift_reg_test.zig,
// long_shift_sat_test.zig and long_shift_sat64_test.zig.

test "seam port: lsll r2, r3, #2 shifts the pair" {
    try std.testing.expectEqual(@as(u64, 0x0000_0007_0000_0004), try run(0xEA52, 0x038F, 0xC000_0001, 1));
}

test "seam port: ordinary shifted-register encodings are no long shift" {
    const ops = ra8.chip.core.cpu.ops;
    // orr.w r3, r3, r2, lsr #30 and and.w r3, r2, pc, lsl #2
    for ([_][2]u16{ .{ 0xEA43, 0x7392 }, .{ 0xEA02, 0x038F } }) |pair| {
        const instr = wide(pair[0], pair[1]);
        try std.testing.expect(long_shift.group.decode(instr) == null);
        try std.testing.expect(ops.long_shift_reg.group.decode(instr) == null);
        try std.testing.expect(ops.long_shift_sat.group.decode(instr) == null);
        try std.testing.expect(ops.long_shift_sat64.group.decode(instr) == null);
    }
}
