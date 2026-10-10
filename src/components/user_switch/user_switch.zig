//! A board user switch (RA8EMU-1043): a push button to ground on a GPIO pin
//! the board pulls high, whose pin also feeds one ICU IRQ channel. Which
//! pins and channels a board wires is the board's to say
//! (src/board/switches.zig for the EK-RA8D2).
const gpio = @import("ra8_chip").periph.gpio;
const pin_irq = @import("ra8_chip").periph.icu_pin_irq;

pub const Switch = struct {
    /// The host-side name, as the touch stream spells it ("sw1").
    name: []const u8,
    port: u8,
    pin: u4,
    /// The IRQ channel the pin feeds.
    irq: u8,
};

/// Hold or let go of `one`. Active-low with a pull-up, so a held switch
/// reads low. The edge for the ICU comes back only when the level changed.
pub fn set(pins: *gpio.Gpio, one: Switch, pressed: bool) ?pin_irq.Edge {
    const was_low = !pins.pinLevel(one.port, one.pin);
    pins.setInput(one.port, one.pin, !pressed);
    if (was_low == pressed) return null;
    return .{ .channel = one.irq, .port = one.port, .pin = one.pin, .falling = pressed };
}
