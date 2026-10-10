//! INTSTS0's summary bits: the mask a dispatching driver reads before it looks
//! at any per-pipe status register.
//!
//! ra8_usb_irq.c's ra8_usb_dispatch reads INTSTS0 once, W0C-acks only the bits
//! it saw, and hands that same value to the registered callback, which is what
//! then goes on to read BRDYSTS or BEMPSTS. So a driver on that path never
//! reaches a per-pipe register until the summary bit above it is up.
//!
//! These are LATCHES, not a live OR of the status registers, and that is the
//! whole point: the dispatcher acks what it read and expects the ack to stick.
//! A computed bit would re-raise itself the instant the ack landed and the
//! driver would dispatch the same packet forever. dev keeps the same shape,
//! event bits in the shadow set explicitly (board_usb_dev.c).
//!
//! NOT MODELLED, AND NOT GUESSED: the rest of INTSTS0. NRDY has no source here
//! because nothing in this model raises NRDYSTS. CTSQ, DVSQ, VBSTS and VALID
//! are the device role's fields, and dev composes them in a separate USBFS
//! device model (board_usb_dev.c's priv_usb_intsts0) that has a host on the
//! other side of the bus to drive them. This is the host controller, where a
//! SETUP is something the firmware sends rather than receives, so VALID in
//! particular is correctly clear rather than missing.

const regs = @import("regs.zig");

/// The latched half of INTSTS0.
pub const Summary = struct {
    bits: u16 = 0,

    /// A pipe has an answer standing.
    pub fn ready(self: *Summary) void {
        self.bits |= regs.int0.brdy;
    }

    /// A staged buffer has gone out.
    pub fn empty(self: *Summary) void {
        self.bits |= regs.int0.bemp;
    }

    pub fn value(self: *const Summary) u16 {
        return self.bits;
    }

    /// W0C: a written zero clears its bit, a written one preserves it.
    pub fn ack(self: *Summary, written: u16) void {
        self.bits &= written;
    }

    /// A bus reset drops the packets, so it drops the bits that named them.
    pub fn busReset(self: *Summary) void {
        self.bits &= ~(regs.int0.brdy | regs.int0.bemp);
    }
};
