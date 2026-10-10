//! Tests for src/chip/core/part_clock.zig: each core's clock ceiling on each
//! part, against its datasheet row.

const std = @import("std");
const ra8 = @import("ra8");
const part_clock = ra8.chip.core.part.clock;

test "the RA8D2 runs CPU0 at up to 1 GHz and CPU1 at up to 250 MHz" {
    const clocks = part_clock.of(.ra8d2);
    try std.testing.expectEqual(@as(u32, 1_000_000_000), clocks.maxHz(.cpu0));
    try std.testing.expectEqual(@as(u32, 250_000_000), clocks.maxHz(.cpu1));
    try std.testing.expect(std.mem.indexOf(u8, clocks.source, "Table 1.14") != null);
}

test "the RA8P1 runs CPU0 at up to 1 GHz and CPU1 at up to 250 MHz" {
    const clocks = part_clock.of(.ra8p1);
    try std.testing.expectEqual(@as(u32, 1_000_000_000), clocks.maxHz(.cpu0));
    try std.testing.expectEqual(@as(u32, 250_000_000), clocks.maxHz(.cpu1));
    try std.testing.expect(std.mem.indexOf(u8, clocks.source, "Table 1.15") != null);
}

test "CPU1 tops out at a quarter of CPU0 on both parts" {
    for ([_]ra8.chip.core.part.Part{ .ra8d2, .ra8p1 }) |part| {
        const clocks = part_clock.of(part);
        try std.testing.expectEqual(clocks.maxHz(.cpu0), 4 * clocks.maxHz(.cpu1));
    }
}
