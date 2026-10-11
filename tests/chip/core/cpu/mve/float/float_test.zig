//! Covers src/chip/core/cpu/mve/float/float.zig.
const std = @import("std");
const ra8 = @import("ra8");
const float = ra8.chip.core.cpu.mve.float;
const Fpscr = ra8.chip.core.cpu.fpu.fpscr.Fpscr;

test "standard forces RN, DN and FZ but keeps FZ16 and AHP" {
    const s = float.standard(.{ .rmode = .zero, .fz16 = 1, .ahp = 1, .ioc = 1 });
    try std.testing.expectEqual(ra8.chip.core.cpu.fpu.fpscr.RMode.nearest, s.rmode);
    try std.testing.expectEqual(@as(u1, 1), s.dn);
    try std.testing.expectEqual(@as(u1, 1), s.fz);
    try std.testing.expectEqual(@as(u1, 1), s.fz16);
    try std.testing.expectEqual(@as(u1, 1), s.ahp);
    try std.testing.expectEqual(@as(u1, 0), s.ioc);
}

test "the caller's controls survive and flags only accumulate" {
    var fpscr: Fpscr = .{ .rmode = .zero, .ufc = 1 };
    _ = float.binary(0, 0x7F800000, 0xFF800000, .word, .add, 0xFFFF, &fpscr);
    try std.testing.expectEqual(ra8.chip.core.cpu.fpu.fpscr.RMode.zero, fpscr.rmode);
    try std.testing.expectEqual(@as(u1, 0), fpscr.dn);
    try std.testing.expectEqual(@as(u1, 1), fpscr.ioc);
    try std.testing.expectEqual(@as(u1, 1), fpscr.ufc);
}
