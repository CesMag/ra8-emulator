const std = @import("std");
const win32 = @import("ra8").interfaces.win32;

test "std handle selectors match STD_INPUT_HANDLE and STD_OUTPUT_HANDLE" {
    try std.testing.expectEqual(@as(u32, 0xFFFF_FFF6), win32.std_input);
    try std.testing.expectEqual(@as(u32, 0xFFFF_FFF5), win32.std_output);
}
