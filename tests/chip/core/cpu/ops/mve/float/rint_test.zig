//! Covers src/chip/core/cpu/ops/mve/float/rint.zig. The encodings come from
//! LLVM's assembler for -mcpu=cortex-m85 with MVE floating point.
const std = @import("std");
const ra8 = @import("ra8");
const Cpu = ra8.chip.core.cpu.cpu.Cpu;
const Instr = ra8.chip.core.cpu.instr.Instr;
const rint = ra8.chip.core.cpu.ops.mve.float.rint;
const qreg = ra8.chip.core.cpu.mve.qreg;
const decode = ra8.chip.core.cpu.decode;

fn wide(hw1: u16, hw2: u16) Instr {
    return .{ .address = 0, .hw1 = hw1, .hw2 = hw2, .size = 4 };
}

fn run(cpu: *Cpu, hw1: u16, hw2: u16) !u128 {
    const instr = wide(hw1, hw2);
    const exec = rint.group.decode(instr) orelse return error.NotClaimed;
    try exec(cpu, instr);
    return qreg.read(&cpu.fp.bank, 0);
}

// q1 = {2.5, -2.5, 1.5, -0.5} as F32.
fn loaded() Cpu {
    var cpu: Cpu = .{ .bus = undefined };
    qreg.write(&cpu.fp.bank, 1, 0xBF000000_3FC00000_C0200000_40200000);
    return cpu;
}

test "each F32 rounding picks its own direction" {
    const cases = [_]struct { hw2: u16, out: u128 }{
        // N: {2, -2, 2, -0}
        .{ .hw2 = 0x0442, .out = 0x80000000_40000000_C0000000_40000000 },
        // A: {3, -3, 2, -1}
        .{ .hw2 = 0x0542, .out = 0xBF800000_40000000_C0400000_40400000 },
        // Z: {2, -2, 1, -0}
        .{ .hw2 = 0x05C2, .out = 0x80000000_3F800000_C0000000_40000000 },
        // M: {2, -3, 1, -1}
        .{ .hw2 = 0x06C2, .out = 0xBF800000_3F800000_C0400000_40000000 },
        // P: {3, -2, 2, -0}
        .{ .hw2 = 0x07C2, .out = 0x80000000_40000000_C0000000_40400000 },
    };
    for (cases) |c| {
        var cpu = loaded();
        try std.testing.expectEqual(c.out, try run(&cpu, 0xFFBA, c.hw2));
        try std.testing.expectEqual(@as(u1, 0), cpu.fp.fpscr.ixc);
    }
}

test "vrintx.f32 rounds to nearest and raises IXC" {
    var cpu = loaded();
    try std.testing.expectEqual(@as(u128, 0x80000000_40000000_C0000000_40000000), try run(&cpu, 0xFFBA, 0x04C2));
    try std.testing.expectEqual(@as(u1, 1), cpu.fp.fpscr.ixc);
}

test "F16 forms: vrintn.f16 q7, q6 and vrintz.f16 q2, q4" {
    var cpu: Cpu = .{ .bus = undefined };
    qreg.write(&cpu.fp.bank, 6, 0x4100_C100_4100_C100_4100_C100_4100_C100);
    var instr = wide(0xFFB6, 0xE44C);
    try (rint.group.decode(instr) orelse return error.NotClaimed)(&cpu, instr);
    try std.testing.expectEqual(@as(u128, 0x4000_C000_4000_C000_4000_C000_4000_C000), qreg.read(&cpu.fp.bank, 7));
    qreg.write(&cpu.fp.bank, 4, 0x3E00_BE00_3E00_BE00_3E00_BE00_3E00_BE00);
    instr = wide(0xFFB6, 0x45C8);
    try (rint.group.decode(instr) orelse return error.NotClaimed)(&cpu, instr);
    try std.testing.expectEqual(@as(u128, 0x3C00_BC00_3C00_BC00_3C00_BC00_3C00_BC00), qreg.read(&cpu.fp.bank, 2));
}

test "the table routes every form here" {
    for ([_][2]u16{
        .{ 0xFFBA, 0x0442 }, .{ 0xFFBA, 0x04C2 }, .{ 0xFFBA, 0x0542 }, .{ 0xFFBA, 0x05C2 },
        .{ 0xFFBA, 0x06C2 }, .{ 0xFFBA, 0x07C2 }, .{ 0xFFB6, 0xE44C }, .{ 0xFFB6, 0x45C8 },
    }) |e| {
        const hit = decode.decode(wide(e[0], e[1])) orelse return error.NotClaimed;
        try std.testing.expectEqualStrings("mve_float_rint", hit.group);
    }
}

test "unclaimed: op 100 or 110, size 0 or 3, D or M set" {
    try std.testing.expect(rint.fields(wide(0xFFBA, 0x0642)) == null);
    try std.testing.expect(rint.fields(wide(0xFFBA, 0x0742)) == null);
    try std.testing.expect(rint.fields(wide(0xFFB2, 0x0442)) == null);
    try std.testing.expect(rint.fields(wide(0xFFBE, 0x0442)) == null);
    try std.testing.expect(rint.fields(wide(0xFFFA, 0x0442)) == null);
    try std.testing.expect(rint.fields(wide(0xFFBA, 0x0462)) == null);
}
