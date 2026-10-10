//! Folds the session's events into the board pane's LEDs (RA8EMU-1081).
//! ui/board_pane.zig keeps its own LED count and lamp colours so it never
//! imports the chip; the asserts below keep them equal to the chip's.
const std = @import("std");
const proto = @import("../rpc/session_rpc.zig");
const gpio = @import("ra8_chip").periph.gpio;
const board_pane = @import("ui/board_pane.zig");

comptime {
    std.debug.assert(board_pane.led_count == gpio.led_count);
    for (gpio.leds, board_pane.led_rgb565) |led, rgb565| std.debug.assert(led.rgb565 == rgb565);
}

/// Takes one session event; anything but a known LED's change is ignored.
pub fn observe(leds: *board_pane.Leds, event: proto.SessionEvent) void {
    if (event.kind != .led_changed) return;
    const index = event.address & 0xFF;
    if (index >= board_pane.led_count) return;
    leds.on[index] = event.address & 0x100 != 0;
}
