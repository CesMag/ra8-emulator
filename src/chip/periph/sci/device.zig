//! Something listening on an SCI channel's line, and when it is listening.
//!
//! A device is handed each byte the channel actually sends and answers with
//! the bytes it drives back, which the channel queues for the firmware to
//! read out of RDR. One device per channel: the AT modem sits on SCI7 this
//! way (src/components/modem_at/modem.zig), the microSD card on SCI0 (src/chip/periph/
//! sd_card_line.zig), and the SPI_B channels use the same shape for the
//! e-ink panel.
//!
//! `spi_only` IS A PIN FACT, NOT A PROTOCOL ONE. A channel's pins are muxed:
//! the Pmod2 slot's SCK / CIPO / COPI / CS reach SCI0 only while the firmware
//! has routed them there and put the channel in Simple-SPI mode, and a
//! channel driven as a UART is talking to whatever is on the UART pins
//! instead. A card that answered an asynchronous channel would be a card
//! nothing on the board is wired to. The modem is the other way round: it is
//! on a UART line, so it leaves this false and hears everything sent.

const gpio = @import("../gpio/gpio.zig");

/// Something on a channel's line.
pub const Device = struct {
    context: *anyopaque,
    feedFn: *const fn (*anyopaque, u8) []const u8,
    /// Only on the line while the channel is in Simple-SPI mode. See the
    /// header: this is about which pins the device is wired to.
    spi_only: bool = false,
    /// Companion models join sideband pins and advance at board boundaries.
    connectFn: ?*const fn (*anyopaque, *gpio.Gpio) void = null,
    tickFn: ?*const fn (*anyopaque, *gpio.Gpio) void = null,

    pub fn connect(self: Device, pins: *gpio.Gpio) void {
        if (self.connectFn) |f| f(self.context, pins);
    }

    pub fn tick(self: Device, pins: *gpio.Gpio) void {
        if (self.tickFn) |f| f(self.context, pins);
    }

    pub fn feed(self: Device, byte: u8) []const u8 {
        return self.feedFn(self.context, byte);
    }
};
