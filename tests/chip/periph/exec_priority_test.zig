//! Tests for src/chip/periph/exec_priority.zig.

const std = @import("std");
const ra8 = @import("ra8");
const mod = ra8.chip.periph.fault_status.exec;

test "nothing boosts thread mode with both masks clear" {
    try std.testing.expectEqual(@as(?u8, null), mod.boosted(null, 0, 0));
}

test "the active handler's priority stands with both masks clear" {
    try std.testing.expectEqual(@as(?u8, 0x40), mod.boosted(0x40, 0, 0));
}

test "PRIMASK boosts to zero from thread mode and from a handler" {
    try std.testing.expectEqual(@as(?u8, 0), mod.boosted(null, 1, 0));
    try std.testing.expectEqual(@as(?u8, 0), mod.boosted(0x80, 1, 0x20));
}

test "PRIMASK reads only bit zero" {
    try std.testing.expectEqual(@as(?u8, null), mod.boosted(null, 0xFFFF_FFFE, 0));
}

test "BASEPRI boosts thread mode to its own value" {
    try std.testing.expectEqual(@as(?u8, 0x60), mod.boosted(null, 0, 0x60));
}

test "BASEPRI only boosts when it is more urgent than the handler" {
    try std.testing.expectEqual(@as(?u8, 0x20), mod.boosted(0x80, 0, 0x20));
    try std.testing.expectEqual(@as(?u8, 0x20), mod.boosted(0x20, 0, 0x80));
}

test "a boosted priority makes an enabled fault escalate" {
    const route = ra8.chip.periph.fault_status.route;
    const shpr1: u32 = 0x0000_4000; // BusFault at 0x40
    const taken = route.route(.bus_fault, 1 << 17, shpr1, mod.boosted(null, 0, 0x40));
    try std.testing.expect(taken.escalated);
    const free = route.route(.bus_fault, 1 << 17, shpr1, mod.boosted(null, 0, 0x80));
    try std.testing.expect(!free.escalated);
}
