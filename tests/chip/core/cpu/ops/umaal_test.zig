//! Covers src/chip/core/cpu/ops/umaal.zig.
const std = @import("std");
const ra8 = @import("ra8");
const Cpu = ra8.chip.core.cpu.cpu.Cpu;
const umaal = ra8.chip.core.cpu.ops.umaal;

fn wide(hw1: u16, hw2: u16) ra8.chip.core.cpu.instr.Instr {
    return .{ .address = 0, .hw1 = hw1, .hw2 = hw2, .size = 4 };
}

/// umaal r0, r1, r2, r3: r1:r0 = r2 * r3 + r1 + r0. Returns r1:r0.
fn run(lo: u32, hi: u32, rn: u32, rm: u32) !u64 {
    var cpu: Cpu = .{ .bus = undefined };
    cpu.regs.low[0] = lo;
    cpu.regs.low[1] = hi;
    cpu.regs.low[2] = rn;
    cpu.regs.low[3] = rm;
    const i = wide(0xFBE2, 0x0163);
    const exec = umaal.group.decode(i) orelse return error.NotClaimed;
    try exec(&cpu, i);
    return (@as(u64, cpu.regs.low[1]) << 32) | cpu.regs.low[0];
}

test "umaal adds both halves to the product" {
    try std.testing.expectEqual(@as(u64, 6 * 7 + 5 + 3), try run(3, 5, 6, 7));
}

test "umaal at the maximum operands fills 64 bits exactly" {
    const m: u32 = 0xFFFF_FFFF;
    try std.testing.expectEqual(@as(u64, 0xFFFF_FFFF_FFFF_FFFF), try run(m, m, m, m));
}

test "umlal row, sp/pc and RdLo == RdHi stay unclaimed" {
    try std.testing.expect(umaal.group.decode(wide(0xFBE2, 0x0103)) == null); // UMLAL
    try std.testing.expect(umaal.group.decode(wide(0xFBED, 0x0163)) == null); // Rn = SP
    try std.testing.expect(umaal.group.decode(wide(0xFBE2, 0x016F)) == null); // Rm = PC
    try std.testing.expect(umaal.group.decode(wide(0xFBE2, 0x0F63)) == null); // RdHi = PC
    try std.testing.expect(umaal.group.decode(wide(0xFBE2, 0x1163)) == null); // RdLo == RdHi
}
