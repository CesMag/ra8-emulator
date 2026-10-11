//! CFDRFSTS: what the receive FIFO tells the firmware about itself, and the
//! one bit in it the firmware is allowed to lower.
//!
//! The register sits at +0x044 per FIFO (`ra8_canfd_regs.h`, CFDRFSTS[2]) and
//! carries four flags:
//!
//!     RFEMP  b0  the FIFO holds nothing
//!     RFFLL  b1  the FIFO holds all it can
//!     RFMLT  b2  a frame arrived with no stage free and was lost
//!     RFIF   b3  a frame is waiting
//!
//! ONLY TWO OF THE FOUR WERE ANSWERED. The block computed RFEMP and RFIF off
//! the queue and left RFFLL and RFMLT at zero forever, so the two flags that
//! report trouble were the two that never appeared. A firmware watching RFFLL
//! to stop offering frames saw room that was not there, and one watching
//! RFMLT to find out it had overrun was told it never had.
//!
//! That is not a hypothetical on this corpus. `threadx_canfd_demo` transmits
//! 21 frames into a four-stage FIFO faster than its reader drains it, and 17
//! of them were dropped on the floor with the register reading a placid
//! "a frame is waiting" the whole way through. The end-of-run report knew
//! (`17 frame(s) LOST, no receive stage free`), and the firmware, which is the
//! one that could have done something about it, did not.
//!
//! RFEMP AND RFFLL ARE LIVE STATUS, derived from the queue every read the way
//! RFEMP already was. Neither latches and neither is clearable: the FIFO is
//! full or it is not, and a store cannot argue with it.
//!
//! RFMLT IS A LATCH, because the event it reports is over by the time anyone
//! reads it. It goes up when a delivery finds no stage free and stays up until
//! the firmware lowers it.
//!
//! THE CLEAR IS WRITE-ZERO-TO-CLEAR, by this block's own convention rather
//! than a page read for RFMLT itself, and that distinction is worth stating.
//! No header in this tree gives RFMLT's clear protocol. What this tree does
//! have is the same chapter's rule for the sibling status register, quoted in
//! `ra8_canfd.c` and modelled in `error_flags.zig`:
//!
//!     /* HUM Ch 41 p 2772 "CFDCnERFL" -- error flags are W0C: writing 0
//!      * clears, writing 1 leaves untouched. */
//!
//! So a store here can lower RFMLT and can never raise it, and a store that
//! carries a one at a flag the controller owns is counted rather than obeyed.
//! Following the block's documented convention beats both alternatives: a
//! flag that never clears would strand a driver that acks correctly, and a
//! W1C guess would let a driver's own acknowledgement invent an overrun.
const lanes = @import("../../lanes.zig");

/// Where the register sits inside a channel window.
pub const off: u32 = 0x044;

pub const field = struct {
    /// RFEMP b0: the FIFO holds nothing.
    pub const rfemp: u32 = 1 << 0;
    /// RFFLL b1: the FIFO holds all it can.
    pub const rffll: u32 = 1 << 1;
    /// RFMLT b2: a frame was lost for want of a stage.
    pub const rfmlt: u32 = 1 << 2;
    /// RFIF b3: a frame is waiting.
    pub const rfif: u32 = 1 << 3;
};

/// The one flag a store may lower. Everything else the controller owns.
pub const writable: u32 = field.rfmlt;

/// The latched half of CFDRFSTS. The live half is the FIFO itself, which is
/// why this holds no copy of it.
pub const Status = struct {
    /// RFMLT, standing until the firmware lowers it.
    lost_latched: bool = false,
    /// Stores that carried a one at a flag only the controller raises.
    invented: u32 = 0,
    /// Stores that lowered RFMLT.
    acknowledged: u32 = 0,

    pub fn quiet(self: *const Status) bool {
        return !self.lost_latched and self.invented == 0 and self.acknowledged == 0;
    }

    /// A frame found no stage free.
    pub fn lose(self: *Status) void {
        self.lost_latched = true;
    }

    /// What a read answers, given the queue's own live state.
    pub fn read(self: *const Status, empty: bool, full: bool) u32 {
        var word: u32 = 0;
        if (empty) word |= field.rfemp else word |= field.rfif;
        if (full) word |= field.rffll;
        if (self.lost_latched) word |= field.rfmlt;
        return word;
    }

    /// A store. Only the lanes the access names are touched. A zero at
    /// RFMLT lowers it; a one anywhere the controller owns is counted and
    /// changes nothing.
    pub fn store(self: *Status, lane: u32, width: u3, value: u32) void {
        const named = lanes.named(lane, width);
        const carried = value & named;
        // A one at any flag is a store trying to raise what only the
        // controller raises, RFMLT included.
        if (carried & (field.rfemp | field.rffll | field.rfmlt | field.rfif) != 0) {
            self.invented +%= 1;
        }
        if (named & writable == 0) return;
        if (carried & field.rfmlt != 0) return;
        if (self.lost_latched) self.acknowledged +%= 1;
        self.lost_latched = false;
    }
};
