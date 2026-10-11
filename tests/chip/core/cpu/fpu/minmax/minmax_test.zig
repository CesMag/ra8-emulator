const std = @import("std");
const ra8 = @import("ra8");
const fpu = ra8.chip.core.cpu.fpu;
const single = fpu.format.single;

test "FPMax itself propagates a quiet NaN" {
    var fpscr: fpu.fpscr.Fpscr = .{};
    try std.testing.expectEqual(@as(u32, 0x7FC0_0000), fpu.minmax.pick(single, 0x7FC0_0000, 0x3F80_0000, .max, &fpscr));
    try std.testing.expectEqual(@as(u32, 0), fpu.case.flagsOf(fpscr));
}

test "FPMin picks the smaller of two negatives" {
    var fpscr: fpu.fpscr.Fpscr = .{};
    try std.testing.expectEqual(@as(u32, 0xC000_0000), fpu.minmax.pick(single, 0xBF80_0000, 0xC000_0000, .min, &fpscr));
}

test "equal values return that value" {
    var fpscr: fpu.fpscr.Fpscr = .{};
    try std.testing.expectEqual(@as(u32, 0x4040_0000), fpu.minmax.num(single, 0x4040_0000, 0x4040_0000, .max, &fpscr));
}
