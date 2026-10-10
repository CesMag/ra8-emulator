//! The EK-RA8D2's two user switches (UM Tbl 25, RA8EMU-1043), both on PORT0
//! with board pull-ups: SW1 = P009 on IRQ13, SW2 = P008 on IRQ12.
const gpio = @import("ra8_chip").periph.gpio;
const user_switch = @import("ra8_components").user_switch;

pub const user = [_]user_switch.Switch{
    .{ .name = "sw1", .port = 0, .pin = 9, .irq = 13 },
    .{ .name = "sw2", .port = 0, .pin = 8, .irq = 12 },
};

/// A port block with the switches' pull-ups in place, so a released switch
/// reads high from the first fetch and after every reset.
pub fn pulled() gpio.Gpio {
    var pins = gpio.Gpio.init();
    for (user) |one| pins.pullUp(one.port, one.pin);
    return pins;
}
