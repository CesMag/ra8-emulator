//! Tests for src/interfaces/gui/wall_clock.zig (RA8EMU-1118): the host clock
//! starts near zero, never runs backwards and moves across a sleep, and a
//! clock calls through to whatever stands behind it.
const std = @import("std");
const gui_app = @import("gui_app");
const Manual = @import("manual_clock.zig").Manual;

const wall_clock = gui_app.wall_clock;

test "the host clock counts up from when it was made" {
    var host = wall_clock.Host.init(std.testing.io);
    const clock = host.clock();
    const first = clock.now();
    try std.testing.expect(first < std.time.ns_per_s);
    try std.testing.io.sleep(.fromMilliseconds(2), .awake);
    const later = clock.now();
    try std.testing.expect(later >= first + std.time.ns_per_ms);
    try std.testing.expect(clock.now() >= later);
}

test "a clock reads whatever stands behind it" {
    var manual: Manual = .{ .now_ns = 40, .step_ns = 2 };
    const clock = manual.clock();
    try std.testing.expectEqual(@as(u64, 40), clock.now());
    try std.testing.expectEqual(@as(u64, 42), clock.now());
    manual.now_ns = 1000;
    try std.testing.expectEqual(@as(u64, 1000), clock.now());
}
