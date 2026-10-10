//! Covers src/chip/core/cpu/memory/extra.zig.
const std = @import("std");
const ra8 = @import("ra8");
const extra = ra8.chip.core.cpu.memory.extra;

test "a mapped window reads zero and answers inside its range only" {
    var windows: extra.Extra = .{};
    defer windows.deinit();
    try windows.map(0x02E0_7000, 0x2000);
    const bytes = windows.span(0x02E0_7FFC, 4).?;
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0 }, bytes);
    try std.testing.expect(windows.span(0x02E0_8FFE, 4) == null);
    try std.testing.expect(windows.span(0x02E0_6FFF, 1) == null);
}

test "a range touching a held window is refused with Mapped" {
    var windows: extra.Extra = .{};
    defer windows.deinit();
    try windows.map(0x02C1_E000, 0x1000);
    try std.testing.expectError(extra.Error.Mapped, windows.map(0x02C1_E000, 0x1000));
    try std.testing.expectError(extra.Error.Mapped, windows.map(0x02C1_D000, 0x2000));
    try windows.map(0x02C1_F000, 0x1000);
}

test "a full table refuses one more window" {
    var windows: extra.Extra = .{};
    defer windows.deinit();
    for (0..extra.capacity) |index| try windows.map(0x0300_0000 + @as(u32, @intCast(index)) * 0x1000, 0x1000);
    try std.testing.expectError(extra.Error.Full, windows.map(0x0400_0000, 0x1000));
}
