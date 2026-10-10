//! A serial channel's error latches: what CSR reports that firmware has to
//! clear rather than outgrow.
//!
//! Split out of src/chip/periph/sci/sci.zig, which owns the channel, the data port and
//! the transmit gate. The bits themselves and the clear lines over them are
//! src/chip/periph/sci/status.zig's; this file owns whether one is standing.
//!
//! WHY A LATCH AND NOT A DERIVED BIT. TDRE, TEND and RDRF are facts about the
//! moment: the transmitter is drained, or the receive ring has a byte. ORER
//! is a fact about something that ALREADY HAPPENED and that only firmware can
//! acknowledge, so draining the ring must not put it down. That is the whole
//! difference, and it is why CFCLR.ORERC is the one line of either clear
//! strobe that does anything.
//!
//! ONLY ORER LIVES HERE SO FAR. FER and PER are the other two flags
//! ra8_sci_get_errors reads out of CSR, and neither has a source in this
//! model: there is no baud clock to frame against and no line to hear noise
//! on. When one gets a source it belongs in this struct beside the overrun,
//! which is why this is a struct of flags rather than a bare bool.

const sci_status = @import("status.zig");

/// The error state of one channel.
pub const Errors = struct {
    /// CSR.ORER: a character arrived with the previous one still unread.
    overrun: bool = false,
    /// Overruns seen, kept apart from the latch so a run still reports the
    /// count after the driver has cleared the flag.
    overruns: u32 = 0,

    /// The receive ring could not hold what the line drove.
    pub fn raiseOverrun(self: *Errors) void {
        self.overrun = true;
        self.overruns +%= 1;
    }

    /// A store to CFCLR. The bit comes out of the value the access carries,
    /// already folded into the register's lanes by the caller, never out of a
    /// shadow this write-only register has not got.
    pub fn clear(self: *Errors, value: u32) void {
        if (sci_status.clearsOverrun(value)) self.overrun = false;
    }

    /// The CSR error bits this channel is currently reporting.
    pub fn flags(self: *const Errors) u32 {
        return if (self.overrun) sci_status.csr.orer else 0;
    }

    pub fn quiet(self: *const Errors) bool {
        return self.overruns == 0;
    }
};
