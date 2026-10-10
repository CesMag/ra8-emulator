//! A push button on a GPIO pin, the part a run attaches with `button`.
const gpio_pins = @import("ra8_chip").periph.gpio.pins;

/// A push button to ground with a pull-up: released reads high, pressed
/// reads low, the same as SW1 and SW2 on the board.
pub const Button = struct {
    link: ?gpio_pins.Link = null,
    pressed: bool = false,

    pub fn press(self: *Button) void {
        self.pressed = true;
        self.drive();
    }

    pub fn release(self: *Button) void {
        self.pressed = false;
        self.drive();
    }

    fn drive(self: *Button) void {
        if (self.link) |link| link.drive(!self.pressed);
    }

    pub fn device(self: *Button) gpio_pins.Device {
        return .{ .context = self, .connectFn = connect, .heardFn = ignore };
    }

    fn connect(context: *anyopaque, link: gpio_pins.Link) void {
        const self: *Button = @ptrCast(@alignCast(context));
        self.link = link;
        self.drive();
    }

    fn ignore(_: *anyopaque, _: bool) void {}
};
