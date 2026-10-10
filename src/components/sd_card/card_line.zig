//! The Pmod2 microSD card as something on an SCI channel's line.
//!
//! The card model itself (src/chip/periph/sd_card.zig) speaks one byte out, one
//! byte back, which is what an SPI_B channel drives it through. An SCI
//! channel in Simple-SPI mode drives the same wire and wants the same
//! exchange, but its device seam answers with a slice rather than a byte,
//! because a UART device (the AT modem) can answer a command with a whole
//! line. This file is that adapter and nothing else: one byte in, the card's
//! one byte out, held in a buffer the channel can borrow.
//!
//! WHY THE CARD MOVED OFF SPI_B. Where the card sits was the model's own
//! rule rather than a register, and sd_card.zig said so. The board says
//! otherwise: k_ra8_board_pmod2_sci_channel = 0, "Pmod2 (J25) Simple-SPI is
//! SCI0", and ra8_sdmmc_spi's transport helper takes an SCI channel and
//! brings it up in Simple-SPI controller mode. Every image in this tree that
//! reaches a card reaches it that way, so the card is on SCI0 and no longer
//! on SPI_B channel 0, where nothing was clocking it.
//!
//! ONE CARD, ONE LINE, still. The card is attached to this channel alone: a
//! single framer fed by two lines is what dev does, and two channels talking
//! at once would interleave into one command and neither would notice.
//!
//! NOT MODELLED, AND NOT GUESSED: the chip select. The driver drives CS
//! through a GPIO pin and the card self-frames off a command's `01xxxxxx`
//! lead bits instead, which is what sd_card.zig already documents. A card
//! deselected mid-command is therefore not a state this model has.

const sci = @import("ra8_chip").periph.sci;
const sd_card = @import("card.zig");

/// Which SCI channel the card is wired to: Pmod2 (J25), which is SCI0
/// (k_ra8_board_pmod2_sci_channel in ra8_board_ek_ra8d2_connectors.h).
pub const line_channel: usize = 0;

/// The card, as an SCI device.
pub const Line = struct {
    card: *sd_card.Card,
    /// What the card drove back for the byte just clocked at it. The channel
    /// borrows this between calls, so it is a field rather than a local.
    answer: [1]u8 = .{0},

    pub fn init(card: *sd_card.Card) Line {
        return .{ .card = card };
    }

    pub fn feed(self: *Line, tx: u8) []const u8 {
        self.answer[0] = self.card.exchange(tx);
        return self.answer[0..1];
    }

    /// The seam the SCI channel drives the card through. `spi_only`: the
    /// card is on the channel's SPI pins, so it hears nothing while the
    /// channel is running as a UART.
    pub fn device(self: *Line) sci.Device {
        return .{ .context = self, .feedFn = feedThunk, .spi_only = true };
    }
};

fn feedThunk(context: *anyopaque, byte: u8) []const u8 {
    const self: *Line = @ptrCast(@alignCast(context));
    return self.feed(byte);
}
