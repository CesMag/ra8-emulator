//! Tests for src/chip/core/second/wait.zig.
const std = @import("std");
const ra8 = @import("ra8");
const parking = ra8.chip.core.second.core.parking;

test "a WFE with no event parks until the spurious wake" {
    var wait: parking.Wait = .{};
    try std.testing.expect(wait.arrive());
    try std.testing.expect(wait.parked());
    var turn: u32 = 1;
    while (turn < parking.limits.spurious_after) : (turn += 1) {
        wait.idled(false);
        try std.testing.expect(wait.parked());
    }
    wait.idled(false);
    try std.testing.expect(!wait.parked());
    try std.testing.expectEqual(@as(usize, 1), wait.wakes.spurious);
}

test "an exception taken on the parked core wakes it" {
    var wait: parking.Wait = .{};
    _ = wait.arrive();
    wait.idled(false);
    wait.idled(true);
    try std.testing.expect(!wait.parked());
    try std.testing.expectEqual(@as(usize, 1), wait.wakes.interrupt);
    try std.testing.expectEqual(@as(usize, 0), wait.wakes.spurious);
}

test "a standing event lets the WFE straight through" {
    var wait: parking.Wait = .{};
    wait.events.sev();
    try std.testing.expect(!wait.arrive());
    try std.testing.expect(!wait.parked());
    try std.testing.expectEqual(@as(usize, 0), wait.parks);
}

test "the idle count starts again on every park" {
    var wait: parking.Wait = .{};
    _ = wait.arrive();
    wait.idled(false);
    wait.idled(true);
    _ = wait.arrive();
    try std.testing.expectEqual(@as(u32, 0), wait.idle_turns);
    try std.testing.expectEqual(@as(usize, 2), wait.parks);
}

test "a SEV from the other core wakes a parked core and is counted" {
    var wait: parking.Wait = .{};
    _ = wait.arrive();
    wait.sev();
    try std.testing.expect(!wait.parked());
    try std.testing.expectEqual(@as(usize, 1), wait.wakes.event);
    // A SEV with nobody waiting leaves an event standing, and wakes nothing.
    wait.sev();
    try std.testing.expectEqual(@as(usize, 1), wait.wakes.event);
    try std.testing.expect(!wait.arrive());
}
