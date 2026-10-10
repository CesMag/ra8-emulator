//! The cellular AT modem on the MikroBUS UART, and the difference between a
//! command the modem heard and a line the model answered anyway.
//!
//! SCI7 (RXD7/TXD7) is the MikroBUS UART on the EK-RA8D2, and `ra8_modem_at`
//! clocks a command out of it one TDR store at a time. This is a line state
//! machine on that channel, not a bus block: it hangs off the SCI device seam
//! the same way the SD card and the e-paper panel hang off the SPI one, so
//! the firmware's genuine polled `ra8_sci_getc_polling` path drains the reply
//! out of RDR exactly as it would on the bench. Ported from
//! board_periph_modem.c on dev, with two things that model does not do.
//!
//! AN OVER-LONG LINE IS NOT A COMMAND. dev buffers 63 bytes and silently
//! throws the rest away, then answers whatever prefix it kept as though that
//! were the command the driver sent. Here the overflow marks the line, the
//! answer is the CME error, and the run is told a line was too long: a
//! command that never fit is a driver bug the bench would show.
//!
//! THE MATCH IS V.250's, NOT A BYTE COMPARE: see script.zig.
//!
//! The seam also carries a rule this model gets for free and dev did not
//! have: a byte only reaches the line when CCR0.TE is set, and a reply only
//! reaches the firmware when CCR0.RE is (src/chip/periph/sci/sci.zig).
//!
//! NOT MODELLED, AND NOT GUESSED: command echo (a real part powers up with
//! ATE1 and the script's own ATE0 turns it off, but nothing in this tree says
//! how the driver treats an echoed line, so dev's echo-free wire is kept),
//! the DTR and RI pins, and any timing between the command and its answer.
const std = @import("std");
const sci = @import("ra8_chip").periph.sci;
pub const script = @import("script.zig");

/// RXD7/TXD7: SCI7 is the MikroBUS UART, dev's k_modem_channel.
pub const line_channel: usize = 7;

/// Model sizing. The longest scripted command is nine bytes, so the line
/// buffer is dev's own capacity rather than anything the script needs.
pub const limits = struct {
    pub const command: usize = 64;
};

/// The modelled modem: the line being accumulated, and what the run should
/// be told about the commands it was given.
pub const Modem = struct {
    line: [limits.command]u8 = undefined,
    len: usize = 0,
    /// The line ran past what the modem accepts, so it is no longer the
    /// command the driver sent and will not be matched against the script.
    overrun: bool = false,
    /// Commands the script answered.
    answered: u32 = 0,
    /// Commands answered +CME ERROR because the script has nothing for them.
    errors: u32 = 0,
    /// Lines refused for length.
    overlong: u32 = 0,

    /// Take one transmitted byte and return what the modem drives back,
    /// which is nothing until a line terminates.
    pub fn feed(self: *Modem, byte: u8) []const u8 {
        if (byte == script.control.lf) return &.{};
        if (byte == script.control.cr) return self.answer();
        if (self.len == limits.command) {
            self.overrun = true;
            return &.{};
        }
        self.line[self.len] = byte;
        self.len += 1;
        return &.{};
    }

    /// Answer the completed line and start the next one.
    fn answer(self: *Modem) []const u8 {
        const line = self.line[0..self.len];
        const over = self.overrun;
        self.len = 0;
        self.overrun = false;
        if (over) {
            self.overlong += 1;
            return script.cme_error;
        }
        if (script.answerFor(line)) |response| {
            self.answered += 1;
            return response;
        }
        self.errors += 1;
        return script.cme_error;
    }

    /// The bytes clocked out since the last terminator. A run that ends with
    /// something here sent a command the modem never got to answer.
    pub fn pending(self: *const Modem) []const u8 {
        return self.line[0..self.len];
    }

    pub fn quiet(self: *const Modem) bool {
        return self.answered == 0 and self.errors == 0 and
            self.overlong == 0 and self.len == 0;
    }

    /// The modem as something the SCI channel can put on its line.
    pub fn device(self: *Modem) sci.Device {
        return .{ .context = self, .feedFn = feedThunk };
    }
};

fn feedThunk(context: *anyopaque, byte: u8) []const u8 {
    const self: *Modem = @ptrCast(@alignCast(context));
    return self.feed(byte);
}
