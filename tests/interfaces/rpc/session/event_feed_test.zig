//! Tests for src/interfaces/rpc/session_event_feed.zig (RA8EMU-942): which
//! stream events go out on the session topic, and as which wire kind.
const std = @import("std");
const ra8 = @import("ra8");
const feed = ra8.rpc.session.event_feed;
const proto = ra8.rpc.session.rpc;

test "stream kinds the wire names map to the same wire kind" {
    try std.testing.expectEqual(proto.EventKind.breakpoint_set, feed.wireKind(.breakpoint_set).?);
    try std.testing.expectEqual(proto.EventKind.input_scheduled, feed.wireKind(.input_scheduled).?);
    try std.testing.expectEqual(proto.EventKind.unplugged, feed.wireKind(.unplugged).?);
    try std.testing.expectEqual(proto.EventKind.led_changed, feed.wireKind(.led_changed).?);
}

test "stream kinds with their own topic or no wire name are skipped" {
    try std.testing.expect(feed.wireKind(.uart_byte) == null);
    try std.testing.expect(feed.wireKind(.lcd_frame) == null);
    // RTOS kinds carry the trace topic instead (RA8EMU-832).
    try std.testing.expect(feed.wireKind(.rtos_switch) == null);
    try std.testing.expect(feed.wireKind(.rtos_idle) == null);
    try std.testing.expect(feed.wireKind(.isr_enter) == null);
    try std.testing.expect(feed.wireKind(.isr_leave) == null);
}

test "an LED change carries its index and level in the address" {
    const on: ra8.session.api.Event = .{ .core = .cpu0, .kind = .led_changed, .payload = .{ .led = .{ .index = 2, .level = true } } };
    try std.testing.expectEqual(@as(u32, 0x102), feed.addressOf(on));
    const off: ra8.session.api.Event = .{ .core = .cpu0, .kind = .led_changed, .payload = .{ .led = .{ .index = 0, .level = false } } };
    try std.testing.expectEqual(@as(u32, 0), feed.addressOf(off));
    const point: ra8.session.api.Event = .{ .core = .cpu0, .kind = .breakpoint_set, .address = 0x0200_0040 };
    try std.testing.expectEqual(@as(u32, 0x0200_0040), feed.addressOf(point));
}

test "module loads, unloads and faults go out under their own wire kinds" {
    try std.testing.expectEqual(proto.EventKind.module_loaded, feed.wireKind(.module_loaded).?);
    try std.testing.expectEqual(proto.EventKind.module_unloaded, feed.wireKind(.module_unloaded).?);
    try std.testing.expectEqual(proto.EventKind.module_faulted, feed.wireKind(.module_faulted).?);
}
