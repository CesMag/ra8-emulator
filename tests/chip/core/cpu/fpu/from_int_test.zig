const std = @import("std");
const ra8 = @import("ra8");
const fpu = ra8.chip.core.cpu.fpu;

test "fbits scales the integer down" {
    var fpscr: fpu.fpscr.Fpscr = .{};
    const bits = fpu.from_int.fromFixed(fpu.format.single, 3, 1, false, .nearest, &fpscr);
    try std.testing.expectEqual(@as(u32, 0x3FC0_0000), bits);
}

test "the same bits are negative signed and large unsigned" {
    var fpscr: fpu.fpscr.Fpscr = .{};
    try std.testing.expectEqual(@as(u64, 0xBFF0_0000_0000_0000), fpu.from_int.fromFixed(fpu.format.double, 0xFFFF_FFFF, 0, false, .nearest, &fpscr));
    try std.testing.expectEqual(@as(u64, 0x41EF_FFFF_FFE0_0000), fpu.from_int.fromFixed(fpu.format.double, 0xFFFF_FFFF, 0, true, .nearest, &fpscr));
}
