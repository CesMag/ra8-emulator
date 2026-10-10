//! The user LEDs as the board drives them (RA8EMU-1073): each LED's own
//! colour and whether its pin has it on. `--frame-out` and the GUI window
//! both draw this strip under the panel, so the reading lives here and the
//! render library only takes the values.
const Board = @import("ra8_board").board.Board;
const gpio = @import("ra8_chip").periph.gpio;

/// One user LED: its colour and whether it is lit.
pub const Led = struct { rgb565: u16, on: bool };

/// Every user LED on `board`, in the GPIO table's order.
pub fn of(board: *Board) [gpio.led_count]Led {
    var lit: [gpio.led_count]Led = undefined;
    for (gpio.leds, 0..) |led, i| lit[i] = .{ .rgb565 = led.rgb565, .on = board.pins.ledLevel(i) == 1 };
    return lit;
}
