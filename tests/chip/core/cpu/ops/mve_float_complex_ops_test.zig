//! Covers src/chip/core/cpu/ops/mve_float_vcadd.zig, mve_float_vcmla.zig and
//! mve_float_vcmul.zig. The encodings come from LLVM's assembler for
//! -mcpu=cortex-m85 with MVE floating point.
const std = @import("std");
const ra8 = @import("ra8");
const Cpu = ra8.chip.core.cpu.cpu.Cpu;
const Instr = ra8.chip.core.cpu.instr.Instr;
const ops = ra8.chip.core.cpu.ops;
const qreg = ra8.chip.core.cpu.mve.qreg;
const decode = ra8.chip.core.cpu.decode;

fn wide(hw1: u16, hw2: u16) Instr {
    return .{ .address = 0, .hw1 = hw1, .hw2 = hw2, .size = 4 };
}

fn run(cpu: *Cpu, hw1: u16, hw2: u16) !void {
    const instr = wide(hw1, hw2);
    const hit = decode.decode(instr) orelse return error.NotClaimed;
    try hit.exec(cpu, instr);
}

// q0 = {10, 20, 30, 40}, q1 = {1, 2, 3, 4} and q2 = {5, 6, 7, 8} as F32:
// pairs (1+2i, 3+4i) times (5+6i, 7+8i), accumulated onto (10+20i, 30+40i).
fn loaded() Cpu {
    var cpu: Cpu = .{ .bus = undefined };
    cpu.fp.cpacr = ra8.chip.core.cpu.fpu.cpacr.full_access;
    qreg.write(&cpu.fp.bank, 0, 0x42200000_41F00000_41A00000_41200000);
    qreg.write(&cpu.fp.bank, 1, 0x40800000_40400000_40000000_3F800000);
    qreg.write(&cpu.fp.bank, 2, 0x41000000_40E00000_40C00000_40A00000);
    return cpu;
}

const Case = struct { hw1: u16, hw2: u16, group: []const u8, out: u128 };

const f32_cases = [_]Case{
    .{ .hw1 = 0xFC92, .hw2 = 0x0844, .group = "mve_float_vcadd", .out = 0x41300000_C0A00000_40E00000_C0A00000 },
    .{ .hw1 = 0xFD92, .hw2 = 0x0844, .group = "mve_float_vcadd", .out = 0xC0400000_41300000_C0400000_40E00000 },
    .{ .hw1 = 0xFC32, .hw2 = 0x0844, .group = "mve_float_vcmla", .out = 0x42800000_424C0000_41D00000_41700000 },
    .{ .hw1 = 0xFCB2, .hw2 = 0x0844, .group = "mve_float_vcmla", .out = 0x42880000_C0000000_41F00000_C0000000 },
    .{ .hw1 = 0xFD32, .hw2 = 0x0844, .group = "mve_float_vcmla", .out = 0x41800000_41100000_41600000_40A00000 },
    .{ .hw1 = 0xFDB2, .hw2 = 0x0844, .group = "mve_float_vcmla", .out = 0x41400000_42780000_41200000_41B00000 },
    .{ .hw1 = 0xFE32, .hw2 = 0x0E04, .group = "mve_float_vcmul", .out = 0x41C00000_41A80000_40C00000_40A00000 },
    .{ .hw1 = 0xFE32, .hw2 = 0x0E05, .group = "mve_float_vcmul", .out = 0x41E00000_C2000000_41200000_C1400000 },
    .{ .hw1 = 0xFE32, .hw2 = 0x1E04, .group = "mve_float_vcmul", .out = 0xC1C00000_C1A80000_C0C00000_C0A00000 },
    .{ .hw1 = 0xFE32, .hw2 = 0x1E05, .group = "mve_float_vcmul", .out = 0xC1E00000_42000000_C1200000_41400000 },
};

test "every F32 VCADD, VCMLA and VCMUL rotation on q0, q1, q2" {
    for (f32_cases) |c| {
        var cpu = loaded();
        const hit = decode.decode(wide(c.hw1, c.hw2)) orelse return error.NotClaimed;
        try std.testing.expectEqualStrings(c.group, hit.group);
        try run(&cpu, c.hw1, c.hw2);
        try std.testing.expectEqual(c.out, qreg.read(&cpu.fp.bank, 0));
    }
}

test "F16 forms: vcadd.f16 #90, vcmla.f16 #90 and vcmul.f16 #180" {
    var cpu: Cpu = .{ .bus = undefined };
    cpu.fp.cpacr = ra8.chip.core.cpu.fpu.cpacr.full_access;
    const ones: u128 = 0x3C00_3C00_3C00_3C00_3C00_3C00_3C00_3C00;
    const twos: u128 = 0x4000_4000_4000_4000_4000_4000_4000_4000;
    const neg_one_three: u128 = 0x4200_BC00_4200_BC00_4200_BC00_4200_BC00;
    qreg.write(&cpu.fp.bank, 6, ones);
    qreg.write(&cpu.fp.bank, 5, twos);
    try run(&cpu, 0xFC8C, 0xE84A); // vcadd.f16 q7, q6, q5, #90
    try std.testing.expectEqual(neg_one_three, qreg.read(&cpu.fp.bank, 7));
    qreg.write(&cpu.fp.bank, 3, ones);
    qreg.write(&cpu.fp.bank, 4, ones);
    qreg.write(&cpu.fp.bank, 1, twos);
    try run(&cpu, 0xFCA8, 0x6842); // vcmla.f16 q3, q4, q1, #90
    try std.testing.expectEqual(neg_one_three, qreg.read(&cpu.fp.bank, 3));
    qreg.write(&cpu.fp.bank, 5, twos);
    try run(&cpu, 0xEE38, 0x7E0A); // vcmul.f16 q3, q4, q5, #180
    try std.testing.expectEqual(@as(u128, 0xC000_C000_C000_C000_C000_C000_C000_C000), qreg.read(&cpu.fp.bank, 3));
}

test "vcmul rotation reads rot_hi from bit 12 and rot_lo from bit 0" {
    try std.testing.expectEqual(@as(u2, 0), ops.mve_float_vcmul.rotation(wide(0xFE32, 0x0E04)));
    try std.testing.expectEqual(@as(u2, 1), ops.mve_float_vcmul.rotation(wide(0xFE32, 0x0E05)));
    try std.testing.expectEqual(@as(u2, 2), ops.mve_float_vcmul.rotation(wide(0xFE32, 0x1E04)));
    try std.testing.expectEqual(@as(u2, 3), ops.mve_float_vcmul.rotation(wide(0xFE32, 0x1E05)));
}

test "unclaimed: D, N or M set" {
    try std.testing.expect(!ops.mve_float_vcadd.claims(wide(0xFCD2, 0x0844)));
    try std.testing.expect(!ops.mve_float_vcadd.claims(wide(0xFC92, 0x08C4)));
    try std.testing.expect(!ops.mve_float_vcmla.claims(wide(0xFC72, 0x0844)));
    try std.testing.expect(!ops.mve_float_vcmla.claims(wide(0xFC32, 0x0864)));
    try std.testing.expect(!ops.mve_float_vcmul.claims(wide(0xFE72, 0x0E04)));
    try std.testing.expect(!ops.mve_float_vcmul.claims(wide(0xFE32, 0x0E84)));
    try std.testing.expect(!ops.mve_float_vcmul.claims(wide(0xFE32, 0x0E24)));
}
