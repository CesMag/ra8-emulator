//! Covers src/chip/core/cpu/cond.zig.
const std = @import("std");
const ra8 = @import("ra8");
const cond = ra8.chip.core.cpu.cond;
const flags = ra8.chip.core.cpu.flags;

const N = flags.bits.n;
const Z = flags.bits.z;
const C = flags.bits.c;
const V = flags.bits.v;

/// The reference: ConditionPassed spelled out per condition.
fn reference(c: u4, apsr: u32) bool {
    const n = apsr & N != 0;
    const z = apsr & Z != 0;
    const cf = apsr & C != 0;
    const v = apsr & V != 0;
    return switch (c) {
        0x0 => z,
        0x1 => !z,
        0x2 => cf,
        0x3 => !cf,
        0x4 => n,
        0x5 => !n,
        0x6 => v,
        0x7 => !v,
        0x8 => cf and !z,
        0x9 => !cf or z,
        0xA => n == v,
        0xB => n != v,
        0xC => !z and n == v,
        0xD => z or n != v,
        0xE, 0xF => true,
    };
}

test "every condition against every NZCV combination" {
    for (0..16) |nzcv| {
        const apsr: u32 = @as(u32, @intCast(nzcv)) << 28;
        for (0..16) |c| {
            const code: u4 = @intCast(c);
            try std.testing.expectEqual(reference(code, apsr), cond.passed(code, apsr | 0x0100_0000));
        }
    }
}
