//! Tests for src/chip/core/rate.zig.

const std = @import("std");
const ra8 = @import("ra8");
const rate = ra8.chip.core.second_core.rate;

test "at reset both cores run the same clock and CPU1 gets the whole round" {
    try std.testing.expectEqual(@as(u32, 500_000), rate.turn(500_000, 0));
}

test "the bring-up dividers give CPU1 a quarter of each round" {
    // internal_program_dividers: CPUCLK0 /1, CPUCLK1 /4, MRICLK /4.
    try std.testing.expectEqual(@as(u32, 125_000), rate.turn(500_000, 0x2020));
}

test "the divide-by-three codes scale the turn too" {
    // CPUCLK0 /3 (code 8), CPUCLK1 /6 (code 9): CPU1 at half CPU0.
    try std.testing.expectEqual(@as(u32, 250_000), rate.turn(500_000, 0x98));
}

test "a prohibited divider code leaves the turn at a full round" {
    try std.testing.expectEqual(@as(u32, 500_000), rate.turn(500_000, 0x70));
    try std.testing.expectEqual(@as(u32, 500_000), rate.turn(500_000, 0x07));
}

test "a slow CPU1 is never starved of its turn" {
    // CPUCLK1 /64 against a one-instruction round still runs one.
    try std.testing.expectEqual(@as(u32, 1), rate.turn(1, 0x60));
}

test "a CPU1 faster than CPU0 gets more than a round" {
    try std.testing.expectEqual(@as(u32, 8), rate.turn(4, 0x01));
}
