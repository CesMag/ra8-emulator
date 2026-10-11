//! Covers src/chip/core/cpu/mve/float/cvt/cvt.zig.
const std = @import("std");
const ra8 = @import("ra8");
const float_cvt = ra8.chip.core.cpu.mve.float.cvt;

test "VCVTT.F32.F16 raises nothing when the top half it reads is not predicated" {
    var fpscr: ra8.chip.core.cpu.fpu.fpscr.Fpscr = .{};
    const m: u128 = 0x7D00_0000;
    const d: u128 = 0xFFFFFFFF;
    try std.testing.expectEqual(@as(u128, 0xFFFF0000), float_cvt.fromHalf(d, m, true, 0x0003, &fpscr));
    try std.testing.expectEqual(@as(u1, 0), fpscr.ioc);
}

test "VCVTT.F16.F32 writes only the top half under a top-half mask" {
    var fpscr: ra8.chip.core.cpu.fpu.fpscr.Fpscr = .{};
    const m: u128 = 0x3F800000;
    try std.testing.expectEqual(@as(u128, 0x3C001111), float_cvt.toHalf(0x22221111, m, true, 0x000C, &fpscr));
    try std.testing.expectEqual(@as(u32, 0), ra8.chip.core.cpu.fpu.case.flagsOf(fpscr));
}
