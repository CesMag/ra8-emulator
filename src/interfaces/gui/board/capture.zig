//! Folds the session's events into the board pane's LEDs (RA8EMU-1081).
//! ui/board_pane.zig keeps its own LED count and lamp colours, because the
//! GUI never imports the chip; the pane's test holds them equal to the
//! chip's.
const proto = @import("ra8_rpc").session.rpc;
const board_pane = @import("../ui/board_pane.zig");

/// Takes one session event; anything but a known LED's change is ignored.
pub fn observe(leds: *board_pane.Leds, event: proto.SessionEvent) void {
    if (event.kind != .led_changed) return;
    const index = event.address & 0xFF;
    if (index >= board_pane.led_count) return;
    leds.on[index] = event.address & 0x100 != 0;
}
