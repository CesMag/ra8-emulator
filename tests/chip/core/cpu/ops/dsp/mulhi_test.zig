//! Covers src/chip/core/cpu/ops/dsp/mulhi.zig. Encodings are the ones
//! arm-none-eabi-as 13.3 emits for r0 = Rd, r1 = Rn, r2 = Rm, r3 = Ra.
const std = @import("std");
const ra8 = @import("ra8");
const Cpu = ra8.chip.core.cpu.cpu.Cpu;
const dsp_mulhi = ra8.chip.core.cpu.ops.dsp.mulhi;

fn wide(hw1: u16, hw2: u16) ra8.chip.core.cpu.instr.Instr {
    return .{ .address = 0, .hw1 = hw1, .hw2 = hw2, .size = 4 };
}

/// Runs the op with r1 = rn, r2 = rm, r3 = ra; returns r0 and checks the
/// flags were left alone.
fn run(hw1: u16, hw2: u16, rn: u32, rm: u32, ra: u32) !u32 {
    var cpu: Cpu = .{ .bus = undefined };
    cpu.regs.low[1] = rn;
    cpu.regs.low[2] = rm;
    cpu.regs.low[3] = ra;
    cpu.regs.xpsr = 0x0100_0000;
    const exec = dsp_mulhi.group.decode(wide(hw1, hw2)) orelse return error.NotClaimed;
    try exec(&cpu, wide(hw1, hw2));
    try std.testing.expectEqual(@as(u32, 0x0100_0000), cpu.regs.xpsr);
    return cpu.regs.low[0];
}

const Case = struct { hw1: u16, hw2: u16, rn: u32, rm: u32, ra: u32, want: u32 };

const cases = [_]Case{
    // smmul: 0x40000000 * 4 = 1 << 32
    .{ .hw1 = 0xFB51, .hw2 = 0xF002, .rn = 0x4000_0000, .rm = 4, .ra = 0, .want = 1 },
    // smmul of two negatives: -1 * -1 = 1, top word 0
    .{ .hw1 = 0xFB51, .hw2 = 0xF002, .rn = 0xFFFF_FFFF, .rm = 0xFFFF_FFFF, .ra = 0, .want = 0 },
    // smmul of opposite signs: -1 * 1 = -1, top word all ones
    .{ .hw1 = 0xFB51, .hw2 = 0xF002, .rn = 0xFFFF_FFFF, .rm = 1, .ra = 0, .want = 0xFFFF_FFFF },
    // smmulr rounds -1 up to 0
    .{ .hw1 = 0xFB51, .hw2 = 0xF012, .rn = 0xFFFF_FFFF, .rm = 1, .ra = 0, .want = 0 },
    // smmulr: 0x8000_0000 low word rounds up, 0x7FFF_FFFF does not
    .{ .hw1 = 0xFB51, .hw2 = 0xF012, .rn = 0x8000_0000, .rm = 0xFFFF_FFFF, .ra = 0, .want = 1 },
    .{ .hw1 = 0xFB51, .hw2 = 0xF012, .rn = 0x7FFF_FFFF, .rm = 1, .ra = 0, .want = 0 },
    // smmul of the most negative value squared: 2^62, top word 0x4000_0000
    .{ .hw1 = 0xFB51, .hw2 = 0xF002, .rn = 0x8000_0000, .rm = 0x8000_0000, .ra = 0, .want = 0x4000_0000 },
    // smmla adds Ra to the top word
    .{ .hw1 = 0xFB51, .hw2 = 0x3002, .rn = 0x4000_0000, .rm = 4, .ra = 10, .want = 11 },
    // smmla wraps: 0x7FFF_FFFF + 1 = 0x8000_0000
    .{ .hw1 = 0xFB51, .hw2 = 0x3002, .rn = 0x4000_0000, .rm = 4, .ra = 0x7FFF_FFFF, .want = 0x8000_0000 },
    // smmlar: (5 << 32) + 0x8000_0000 product low word rounds up
    .{ .hw1 = 0xFB51, .hw2 = 0x3012, .rn = 0x4000_0000, .rm = 2, .ra = 5, .want = 6 },
    // smmls subtracts: (10 << 32) - (1 << 32) = 9
    .{ .hw1 = 0xFB61, .hw2 = 0x3002, .rn = 0x4000_0000, .rm = 4, .ra = 10, .want = 9 },
    // smmls borrows from the top word: (10 << 32) - 1 = 9:FFFF_FFFF
    .{ .hw1 = 0xFB61, .hw2 = 0x3002, .rn = 1, .rm = 1, .ra = 10, .want = 9 },
    // smmlsr rounds that back up to 10
    .{ .hw1 = 0xFB61, .hw2 = 0x3012, .rn = 1, .rm = 1, .ra = 10, .want = 10 },
};

test "smmul, smmla and smmls against the Arm ARM pseudocode" {
    for (cases) |c| try std.testing.expectEqual(c.want, try run(c.hw1, c.hw2, c.rn, c.rm, c.ra));
}

test "the encodings it leaves alone" {
    const left = [_][2]u16{
        .{ 0xFB61, 0xF002 }, // smmls with Ra = 1111
        .{ 0xFB51, 0xD002 }, // Ra = SP
        .{ 0xFB51, 0xFD02 }, // Rd = SP
        .{ 0xFB5D, 0xF002 }, // Rn = SP
        .{ 0xFB51, 0xF00F }, // Rm = PC
        .{ 0xFB51, 0xF022 }, // hw2[7:5] nonzero
        .{ 0xFB71, 0xF002 }, // not this group
    };
    for (left) |pair| try std.testing.expect(dsp_mulhi.group.decode(wide(pair[0], pair[1])) == null);
}
