//! CFDRFCCa, the RX FIFO's own configuration register, and the two rules
//! that decide whether the FIFO is there to receive anything at all.
//!
//! The FIFO does not power up ready. CFDRFCCa.RFE brings it out of the
//! disabled state, and until that bit stands a frame the acceptance filter
//! took has nowhere to go: the controller drops it rather than queueing it.
//! ra8_canfd.c does this in two deliberate steps and says why in its own
//! doc comments, citing HUM Ch 41 "CFDRFCCa" pp 2741-2742:
//!
//!   internal_configure_rx_fifo0  RFDC and RFPLS, written in GL_RESET
//!   internal_enable_rx_fifo0     RFE alone, written in GL_OPERATION
//!
//! It splits them because RFE DOES NOT TAKE IN GL_RESET ("Setting RFE here
//! would silently no-op, the FIFO would stay disabled, and every loopback
//! frame would land in /dev/null instead of the RX FIFO"), and because RFE
//! does not take while RFDC is zero either ("This bit can only be set if
//! the configured FIFO depth is greater than 0x000"). Both are refusals of
//! the SET only: clearing RFE is allowed from anywhere.
//!
//!   CFDRFCC[0]  +0x03C   (ra8_canfd_regs.h: offset 0x03C..0x043, two FIFOs)
//!     RFE   [0]    enable the FIFO
//!     RFIE  [1]    raise the receive interrupt
//!     RFDC  [10:8] how many frames it holds
//!
//! RFDC IS READ ONLY AS ZERO OR NON-ZERO, deliberately. The one encoding
//! this tree documents is ra8_canfd.c's `k_rfcc_rfdc_4msgs = 1UL << 8U`,
//! four entries; nothing here gives the rest of the field, so the depth
//! stays src/chip/periph/canfd/canfd_fifo.zig's stated four rather than a guessed
//! decode of a field we have one point of.

/// CFDRFCC[0]. CFDRFCC[1] is the second FIFO, which this model does not
/// route anything into.
pub const off_rfcc0: u32 = 0x03C;

pub const field = struct {
    pub const rfe: u32 = 1 << 0;
    pub const rfie: u32 = 1 << 1;
    pub const rfdc: u32 = 0x7 << 8;
};

/// CFDRFCC[0] as the firmware left it, and the enables it did not get.
pub const Config = struct {
    word: u32 = 0,
    /// Stores that asked for RFE and did not get it, because the global
    /// machine was in reset or RFDC was still zero.
    refused: u32 = 0,

    /// Is the FIFO out of the disabled state?
    pub fn enabled(self: Config) bool {
        return self.word & field.rfe != 0;
    }

    /// Would a receive raise the line? Nothing in this model routes it yet,
    /// so this is read by the report rather than by the event path.
    pub fn interrupting(self: Config) bool {
        return self.word & field.rfie != 0;
    }

    /// Whether a depth has been programmed at all.
    pub fn sized(self: Config) bool {
        return self.word & field.rfdc != 0;
    }

    /// Take a store. `wanted` is the whole register as the access leaves it;
    /// `in_reset` is the global machine's state, which is what decides
    /// whether an RFE this store asks for takes.
    pub fn store(self: *Config, wanted: u32, in_reset: bool) void {
        const asking = wanted & field.rfe != 0 and !self.enabled();
        const may = !in_reset and wanted & field.rfdc != 0;
        if (asking and !may) {
            self.word = wanted & ~field.rfe;
            self.refused +%= 1;
            return;
        }
        self.word = wanted;
    }

    pub fn quiet(self: Config) bool {
        return self.word == 0 and self.refused == 0;
    }
};
