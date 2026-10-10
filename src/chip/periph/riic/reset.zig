//! ICE and IICRST: which accesses the interface answers, and when (HUM Ch
//! 39.2.1 "ICCR1 : I2C Bus Control Register 1", p 2369, and the open sequence
//! in HUM Ch 39.3.2, p 2395).
//!
//! Two bits in ICCR1, two different jobs, and the model used to run them
//! together. ICE powers the register file: with it clear the block answers
//! nothing, which is the real "the firmware never enabled this" case worth
//! counting. IICRST holds the transfer machine in an internal reset: the bus
//! goes idle and no condition can be issued, but THE REGISTERS ARE STILL
//! THERE AND STILL WRITABLE.
//!
//! That distinction is not a nicety, it is the whole point of the reset. HUM
//! Ch 39.3.2 has the driver hold IICRST, set ICE, program the bit rate and
//! the function bits, and only then release the reset, because those are the
//! registers that may not be moved while the machine is running.
//! ra8_i2c_config.c walks exactly that sequence and says so by page:
//!
//!     reg->ICCR1 = 0;                     // ICE 0, IICRST 0
//!     reg->ICCR1 = iicrst;                // hold the reset
//!     reg->ICCR1 = iicrst | ice;          // power it, still held
//!     reg->ICMR1 = cks << pos;            //   <- CKS divider
//!     reg->ICBRL = brl;                   //   <- bit rate, low half
//!     reg->ICBRH = brh;                   //   <- bit rate, high half
//!     reg->ICFER = icfer;                 //   <- function enables
//!     reg->ICCR1 = ice;                   // release
//!
//! Gating register access on "ICE set AND IICRST clear" refused all four of
//! those stores, which is every setting the sequence exists to program. The
//! channel then ran on whatever the shadow happened to hold and the run
//! reported the four as accesses to a disabled interface, blaming the
//! firmware for following the manual.
//!
//! So: ICE alone decides whether an access is answered, and IICRST decides
//! whether the BUS can move. Only the registers that move it are refused
//! while the reset is held; configuration takes its ordinary path, keeping
//! the rules that do not depend on the bus (ICMR3's ACKWP write protection,
//! the target addresses in SARLn), which is what the driver came to do.
const flag = @import("flags.zig");

/// ICE set: the register file answers. This is the gate an access passes
/// before anything else, and failing it is the genuine uninitialised case.
pub fn powered(setup: u8) bool {
    return setup & flag.iccr1.ice != 0;
}

/// ICE set and IICRST clear: the transfer machine is out of reset, so a
/// START can be issued and a byte can be clocked.
pub fn running(setup: u8) bool {
    return powered(setup) and setup & flag.iccr1.iicrst == 0;
}

/// The registers that move the bus rather than describe it. Everything else
/// in the window is configuration a driver is meant to program while the
/// reset is held, so only these two are refused during it.
pub fn movesBus(offset: u32) bool {
    return offset == flag.reg.iccr2 or offset == flag.reg.icdrt or
        offset == flag.reg.icdrr;
}

/// What an access to a register other than ICCR1 may do.
pub const Verdict = enum {
    /// The access goes through the ordinary path. Either the block is
    /// running, or it is held in reset and this register is configuration,
    /// which is exactly what the driver is in that window to program.
    answer,
    /// ICE clear: nothing is there to answer.
    unpowered,
    /// Powered, but IICRST holds the machine and this register moves the bus.
    held,
};

/// The one decision both the read and the write path make before anything
/// else, so the two cannot drift apart.
pub fn verdict(setup: u8, offset: u32) Verdict {
    if (!powered(setup)) return .unpowered;
    if (running(setup)) return .answer;
    return if (movesBus(offset)) .held else .answer;
}
