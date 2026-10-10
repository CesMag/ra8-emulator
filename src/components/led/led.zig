//! An LED on a GPIO pin, the part a run attaches with `led`.
const gpio_pins = @import("ra8_chip").periph.gpio_pins;

/// An LED on a pin the firmware drives: whether it is lit, and how many
/// times that changed.
pub const Led = struct {
    lit: bool = false,
    edges: u32 = 0,

    pub fn device(self: *Led) gpio_pins.Device {
        return .{ .context = self, .connectFn = connect, .heardFn = heard };
    }

    fn connect(context: *anyopaque, link: gpio_pins.Link) void {
        const self: *Led = @ptrCast(@alignCast(context));
        self.lit = link.level();
    }

    fn heard(context: *anyopaque, high: bool) void {
        const self: *Led = @ptrCast(@alignCast(context));
        if (self.lit == high) return;
        self.lit = high;
        self.edges += 1;
    }
};
