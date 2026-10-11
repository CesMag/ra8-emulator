//! Covers src/chip/core/cpu/ops/dsp_long_mul.zig. Encodings are the ones
//! arm-none-eabi-as 13.3 emits for RdLo = r0, RdHi = r1, Rn = r2, Rm = r3.
const std = @import("std");
const ra8 = @import("ra8");
const Cpu = ra8.chip.core.cpu.cpu.Cpu;
const dsp_long_mul = ra8.chip.core.cpu.ops.dsp.long_mul;

fn wide(hw1: u16, hw2: u16) ra8.chip.core.cpu.instr.Instr {
    return .{ .address = 0, .hw1 = hw1, .hw2 = hw2, .size = 4 };
}

/// Runs the op with r1:r0 = acc, r2 = rn, r3 = rm; returns r1:r0 and
/// checks the flags were left alone.
fn run(hw1: u16, hw2: u16, rn: u32, rm: u32, acc: u64) !u64 {
    var cpu: Cpu = .{ .bus = undefined };
    cpu.regs.low[0] = @truncate(acc);
    cpu.regs.low[1] = @truncate(acc >> 32);
    cpu.regs.low[2] = rn;
    cpu.regs.low[3] = rm;
    cpu.regs.xpsr = 0x0100_0000;
    const exec = dsp_long_mul.group.decode(wide(hw1, hw2)) orelse return error.NotClaimed;
    try exec(&cpu, wide(hw1, hw2));
    try std.testing.expectEqual(@as(u32, 0x0100_0000), cpu.regs.xpsr);
    return (@as(u64, cpu.regs.low[1]) << 32) | cpu.regs.low[0];
}

const Case = struct { hw1: u16, hw2: u16, rn: u32, rm: u32, acc: u64, want: u64 };

// rn = (top 3, bottom -2), rm = (top 5, bottom 7)
const rn_pair: u32 = 0x0003_FFFE;
const rm_pair: u32 = 0x0005_0007;

const cases = [_]Case{
    // smlalbb/bt/tb/tt pick the halves: -2*7, -2*5, 3*7, 3*5, plus 100
    .{ .hw1 = 0xFBC2, .hw2 = 0x0183, .rn = rn_pair, .rm = rm_pair, .acc = 100, .want = 86 },
    .{ .hw1 = 0xFBC2, .hw2 = 0x0193, .rn = rn_pair, .rm = rm_pair, .acc = 100, .want = 90 },
    .{ .hw1 = 0xFBC2, .hw2 = 0x01A3, .rn = rn_pair, .rm = rm_pair, .acc = 100, .want = 121 },
    .{ .hw1 = 0xFBC2, .hw2 = 0x01B3, .rn = rn_pair, .rm = rm_pair, .acc = 100, .want = 115 },
    // a negative product borrows across the 32-bit boundary: 0 + -14
    .{ .hw1 = 0xFBC2, .hw2 = 0x0183, .rn = rn_pair, .rm = rm_pair, .acc = 0, .want = 0xFFFF_FFFF_FFFF_FFF2 },
    // carry from RdLo into RdHi: 0xFFFF_FFFF + 1
    .{ .hw1 = 0xFBC2, .hw2 = 0x0183, .rn = 1, .rm = 1, .acc = 0xFFFF_FFFF, .want = 0x1_0000_0000 },
    // the accumulate wraps at 64 bits
    .{ .hw1 = 0xFBC2, .hw2 = 0x0183, .rn = 1, .rm = 1, .acc = 0xFFFF_FFFF_FFFF_FFFF, .want = 0 },
    // smlald: -2*7 + 3*5 = 1; smlaldx: -2*5 + 3*7 = 11
    .{ .hw1 = 0xFBC2, .hw2 = 0x01C3, .rn = rn_pair, .rm = rm_pair, .acc = 100, .want = 101 },
    .{ .hw1 = 0xFBC2, .hw2 = 0x01D3, .rn = rn_pair, .rm = rm_pair, .acc = 100, .want = 111 },
    // smlald of 0x8000 squared twice is 2^31, which needs RdHi's sign room
    .{ .hw1 = 0xFBC2, .hw2 = 0x01C3, .rn = 0x8000_8000, .rm = 0x8000_8000, .acc = 0, .want = 0x8000_0000 },
    // smlsld: -2*7 - 3*5 = -29; smlsldx: -2*5 - 3*7 = -31
    .{ .hw1 = 0xFBD2, .hw2 = 0x01C3, .rn = rn_pair, .rm = rm_pair, .acc = 100, .want = 71 },
    .{ .hw1 = 0xFBD2, .hw2 = 0x01D3, .rn = rn_pair, .rm = rm_pair, .acc = 100, .want = 69 },
};

test "smlal<x><y>, smlald and smlsld against the Arm ARM pseudocode" {
    for (cases) |c| try std.testing.expectEqual(c.want, try run(c.hw1, c.hw2, c.rn, c.rm, c.acc));
}

test "the encodings it leaves alone" {
    const left = [_][2]u16{
        .{ 0xFBC2, 0x0103 }, // plain smlal: ops/long_mul.zig
        .{ 0xFBD2, 0x0183 }, // 0xFBD0 has no halfword form
        .{ 0xFBC2, 0x01E3 }, // hw2[7:5] = 111
        .{ 0xFBC2, 0x0083 }, // RdHi == RdLo
        .{ 0xFBC2, 0xD183 }, // RdLo = SP
        .{ 0xFBC2, 0x0F83 }, // RdHi = PC
        .{ 0xFBCD, 0x0183 }, // Rn = SP
        .{ 0xFBC2, 0x018F }, // Rm = PC
    };
    for (left) |pair| try std.testing.expect(dsp_long_mul.group.decode(wide(pair[0], pair[1])) == null);
}
