//! Covers src/chip/periph/gpio/pins.zig with the button and LED parts
//! (src/components/button, src/components/led): a model on a
//! pin drives what PIDR reads, hears what the port drives, and keeps its
//! level across a port reset.
const std = @import("std");
const ra8 = @import("ra8");
const mod = ra8.chip.periph.gpio;

const Gpio = mod.Gpio;
const Button = ra8.components.button.Button;
const Led = ra8.components.led.Led;
const regAddress = mod.regAddress;

fn pidr(gpio: *const Gpio, port: u32) u32 {
    return gpio.readReg(regAddress(port, mod.pcntr2), 4);
}

test "a released button reads high and a pressed one low" {
    var gpio = Gpio.init();
    var button = Button{};
    try gpio.wired.attach(&gpio, 0, 6, button.device());
    try std.testing.expect(pidr(&gpio, 0) & (1 << 6) != 0);
    button.press();
    try std.testing.expect(pidr(&gpio, 0) & (1 << 6) == 0);
    button.release();
    try std.testing.expect(pidr(&gpio, 0) & (1 << 6) != 0);
}

test "a held button stays held across a port reset" {
    var gpio = Gpio.init();
    var button = Button{};
    try gpio.wired.attach(&gpio, 1, 2, button.device());
    button.press();
    gpio.reset();
    try std.testing.expect(gpio.readReg(regAddress(1, mod.pcntr2), 4) & (1 << 2) == 0);
    button.release();
    try std.testing.expect(gpio.pinLevel(1, 2));
}

test "an LED hears PCNTR1 and PCNTR3 stores to its pin" {
    var gpio = Gpio.init();
    var led = Led{};
    try gpio.wired.attach(&gpio, 6, 4, led.device());
    gpio.applyWrite(regAddress(6, mod.pcntr1), 4, (@as(u32, 1 << 4) << 16) | (1 << 4));
    try std.testing.expect(led.lit);
    try std.testing.expectEqual(@as(u32, 1), led.edges);
    gpio.applyWrite(regAddress(6, mod.pcntr3), 4, @as(u32, 1 << 4) << 16);
    try std.testing.expect(!led.lit);
    try std.testing.expectEqual(@as(u32, 2), led.edges);
}

test "a store to another port leaves the LED alone" {
    var gpio = Gpio.init();
    var led = Led{};
    try gpio.wired.attach(&gpio, 6, 4, led.device());
    gpio.applyWrite(regAddress(3, mod.pcntr1), 4, (@as(u32, 1 << 4) << 16) | (1 << 4));
    try std.testing.expect(!led.lit);
    try std.testing.expectEqual(@as(u32, 0), led.edges);
}

test "one model per pin, and at most four" {
    var gpio = Gpio.init();
    var leds = @as([5]Led, @splat(.{}));
    try gpio.wired.attach(&gpio, 2, 0, leds[0].device());
    try std.testing.expectError(error.PinTaken, gpio.wired.attach(&gpio, 2, 0, leds[1].device()));
    for (leds[1..4], 1..) |*led, pin| try gpio.wired.attach(&gpio, 2, @intCast(pin), led.device());
    try std.testing.expectError(error.PinsFull, gpio.wired.attach(&gpio, 2, 9, leds[4].device()));
}

test "the C6 link keeps the port observer" {
    var gpio = Gpio.init();
    var led = Led{};
    try gpio.wired.attach(&gpio, 6, 0, led.device());
    try std.testing.expect(gpio.observer == null);
}
