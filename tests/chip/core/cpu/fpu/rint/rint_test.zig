const std = @import("std");
const ra8 = @import("ra8");
const fpu = ra8.chip.core.cpu.fpu;

test "an integral value comes back unchanged without flags" {
    var fpscr: fpu.fpscr.Fpscr = .{};
    try std.testing.expectEqual(@as(u32, 0x4B80_0001), fpu.rint.rint(fpu.format.single, 0x4B80_0001, .nearest, true, &fpscr));
    try std.testing.expectEqual(@as(u32, 0), fpu.case.flagsOf(fpscr));
}

test "rounding up across a power of two still packs exactly" {
    var fpscr: fpu.fpscr.Fpscr = .{};
    try std.testing.expectEqual(@as(u32, 0x4000_0000), fpu.rint.rint(fpu.format.single, 0x3FFF_FFFF, .plus_inf, false, &fpscr));
    try std.testing.expectEqual(@as(u32, 0), fpu.case.flagsOf(fpscr));
}

test "a tiny value toward minus infinity becomes -1" {
    var fpscr: fpu.fpscr.Fpscr = .{};
    try std.testing.expectEqual(@as(u64, 0xBFF0_0000_0000_0000), fpu.rint.rint(fpu.format.double, 0x8000_0000_0000_0001, .minus_inf, false, &fpscr));
}
