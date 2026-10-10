//! Covers src/chip/core/event.zig.
const std = @import("std");
const ra8 = @import("ra8");
const Events = ra8.chip.core.core_event.Events;

test "a WFE with no event waits and a SEV from the other core wakes it" {
    var events: Events = .{};
    try std.testing.expectEqual(.waits, events.wfe(1));
    try std.testing.expect(events.parked(1));
    events.sev();
    try std.testing.expect(!events.parked(1));
    // The wake consumed CPU1's event; CPU0's own bit is still set.
    try std.testing.expectEqual(.waits, events.wfe(1));
    try std.testing.expectEqual(.proceeds, events.wfe(0));
}

test "a SEV before the WFE is not lost" {
    var events: Events = .{};
    events.sev();
    try std.testing.expectEqual(.proceeds, events.wfe(1));
    try std.testing.expectEqual(.waits, events.wfe(1));
}

test "SEV sets the bit on the core that ran it too" {
    var events: Events = .{};
    events.sev();
    try std.testing.expectEqual(.proceeds, events.wfe(0));
    try std.testing.expectEqual(.proceeds, events.wfe(1));
}

test "a local event reaches only its own core" {
    var events: Events = .{};
    events.post(0);
    try std.testing.expectEqual(.waits, events.wfe(1));
    try std.testing.expectEqual(.proceeds, events.wfe(0));
    events.post(1);
    try std.testing.expect(!events.parked(1));
    try std.testing.expectEqual(.waits, events.wfe(1));
}

test "events do not stack: two SEVs let one WFE through" {
    var events: Events = .{};
    events.sev();
    events.sev();
    try std.testing.expectEqual(.proceeds, events.wfe(1));
    try std.testing.expectEqual(.waits, events.wfe(1));
}
