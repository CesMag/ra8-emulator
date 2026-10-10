//! Covers src/chip/core/cpu/ops/usad8.zig.
const std = @import("std");
const ra8 = @import("ra8");
const Cpu = ra8.chip.core.cpu.cpu.Cpu;
const usad8 = ra8.chip.core.cpu.ops.usad8;

fn wide(hw1: u16, hw2: u16) ra8.chip.core.cpu.instr.Instr {
    return .{ .address = 0, .hw1 = hw1, .hw2 = hw2, .size = 4 };
}

/// Runs the op with r1 = rn, r2 = rm, r3 = ra and returns r0.
fn run(hw2: u16, rn: u32, rm: u32, ra: u32) !u32 {
    var cpu: Cpu = .{ .bus = undefined };
    cpu.regs.low[1] = rn;
    cpu.regs.low[2] = rm;
    cpu.regs.low[3] = ra;
    const exec = usad8.group.decode(wide(0xFB71, hw2)) orelse return error.NotClaimed;
    try exec(&cpu, wide(0xFB71, hw2));
    return cpu.regs.low[0];
}

test "usad8 r0, r1, r2 sums absolute byte differences" {
    // |0x10-0x20| + |0xFF-0x01| + |0x05-0x05| + |0x00-0x80| = 16 + 254 + 0 + 128
    try std.testing.expectEqual(@as(u32, 398), try run(0xF002, 0x0005_FF10, 0x8005_0120, 0));
}

test "usada8 r0, r1, r2, r3 adds the accumulator mod 2^32" {
    try std.testing.expectEqual(@as(u32, 0x0000_0003), try run(0x3002, 0x0000_0004, 0x0000_0000, 0xFFFF_FFFF));
}

test "op bits, sp/pc and ra = sp stay unclaimed" {
    try std.testing.expect(usad8.group.decode(wide(0xFB71, 0xF012)) == null); // hw2[7:4]
    try std.testing.expect(usad8.group.decode(wide(0xFB7D, 0xF002)) == null); // Rn = SP
    try std.testing.expect(usad8.group.decode(wide(0xFB71, 0xFF02)) == null); // Rd = PC
    try std.testing.expect(usad8.group.decode(wide(0xFB71, 0xF00F)) == null); // Rm = PC
    try std.testing.expect(usad8.group.decode(wide(0xFB71, 0xD002)) == null); // Ra = SP
    try std.testing.expect(usad8.group.decode(wide(0xFB61, 0xF002)) == null); // SMMLS row
}
