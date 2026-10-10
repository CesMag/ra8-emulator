const std = @import("std");
const ra8 = @import("ra8");
const to_int = ra8.chip.core.cpu.fpu.to_int;

test "saturation picks the nearest end of each range" {
    try std.testing.expectEqual(@as(u32, 0x7FFF_FFFF), to_int.saturate(0, false));
    try std.testing.expectEqual(@as(u32, 0x8000_0000), to_int.saturate(1, false));
    try std.testing.expectEqual(@as(u32, 0xFFFF_FFFF), to_int.saturate(0, true));
    try std.testing.expectEqual(@as(u32, 0), to_int.saturate(1, true));
}
