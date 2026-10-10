//! Tests for src/components/user_switch/user_switch.zig.
const std = @import("std");
const ra8 = @import("ra8");
const user_switch = ra8.components.user_switch;
const gpio = ra8.chip.periph.gpio;

const sw: user_switch.Switch = .{ .name = "sw", .port = 2, .pin = 5, .irq = 7 };

fn pulled() gpio.Gpio {
    var pins = gpio.Gpio.init();
    pins.pullUp(sw.port, sw.pin);
    return pins;
}

test "holding a switch pulls its pin low and hands back a falling edge" {
    var pins = pulled();
    const edge = user_switch.set(&pins, sw, true).?;
    try std.testing.expect(!pins.pinLevel(sw.port, sw.pin));
    try std.testing.expectEqual(@as(u8, 7), edge.channel);
    try std.testing.expectEqual(sw.port, edge.port);
    try std.testing.expectEqual(sw.pin, edge.pin);
    try std.testing.expect(edge.falling);
}

test "letting go raises the pin and hands back a rising edge" {
    var pins = pulled();
    _ = user_switch.set(&pins, sw, true);
    const edge = user_switch.set(&pins, sw, false).?;
    try std.testing.expect(pins.pinLevel(sw.port, sw.pin));
    try std.testing.expect(!edge.falling);
}

test "a set that leaves the level where it was hands back no edge" {
    var pins = pulled();
    try std.testing.expect(user_switch.set(&pins, sw, false) == null);
    _ = user_switch.set(&pins, sw, true);
    try std.testing.expect(user_switch.set(&pins, sw, true) == null);
}
