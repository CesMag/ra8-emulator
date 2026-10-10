//! Covers src/chip/core/cpu/mve/float_complex.zig.
const std = @import("std");
const ra8 = @import("ra8");
const float_complex = ra8.chip.core.cpu.mve.float_complex;

test "a pair with no predicated byte is left alone" {
    var fpscr: ra8.chip.core.cpu.fpu.fpscr.Fpscr = .{};
    const d: u128 = 0x1111_2222;
    try std.testing.expectEqual(d, float_complex.cmla(d, 0x7F800001, 0, .word, 0, true, 0xFF00, &fpscr) & 0xFFFF_FFFF_FFFF_FFFF);
    try std.testing.expectEqual(@as(u1, 0), fpscr.ioc);
}

test "VCADD reads Qn and Qm before writing, so Qd may alias them" {
    var fpscr: ra8.chip.core.cpu.fpu.fpscr.Fpscr = .{};
    const q: u128 = 0x40000000_3F800000; // 1, 2
    // rotate 90: (1 - 2, 2 + 1) = (-1, 3)
    try std.testing.expectEqual(@as(u128, 0x40400000_BF800000), float_complex.cadd(q, q, q, .word, false, 0xFFFF, &fpscr));
}
