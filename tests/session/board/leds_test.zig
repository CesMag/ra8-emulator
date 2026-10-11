//! Covers src/session/board_leds.zig: every user LED keeps its own colour,
//! and it is lit only while its pin drives it on.
const std = @import("std");
const ra8 = @import("ra8");
const board_leds = ra8.session.board.leds;
const gpio = ra8.chip.periph.gpio;

test "a fresh board has every LED dark in its own colour" {
    var board = ra8.board.board.Board.init(std.testing.allocator);
    defer board.deinit();
    const lit = board_leds.of(&board);
    for (lit, gpio.leds) |led, want| {
        try std.testing.expectEqual(want.rgb565, led.rgb565);
        try std.testing.expect(!led.on);
    }
}

test "render's Led is the session's reading" {
    try std.testing.expect(ra8.render.board_view.Led == board_leds.Led);
}
