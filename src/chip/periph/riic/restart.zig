//! The RIIC restart window: ICCR2.RS stands until the driver reads it back,
//! and an ICDRT store made inside that window is dropped.
//!
//! ICCR2.RS auto-clears once the restart condition is issued, and the manual
//! is explicit about what happens before that: "The peripheral address must
//! be written to ICDRT only after RS reads 0 -- a write while RS = 1 is
//! silently dropped (HUM Ch 39.11 Issuing a Restart Condition Note, p 2434)",
//! quoted from `ra8_i2c.c` internal_i2c_restart, which spins on the readback
//! for exactly that reason and says so in place: after a send_stop=false
//! write TDRE is already 1, so without the wait the address would go in
//! before the restart completed and the transmit would never happen.
//!
//! RS used to auto-clear inside the same store, so the window did not exist
//! in this model: the driver's spin loop was satisfied on its first look, and
//! an address written with no wait at all worked. Now the request stands
//! until ICCR2 is read once, and a store while it stands is DROPPED AND
//! COUNTED, the way the page says.
//!
//! THE REFUSAL IS DOCUMENTED; THE WINDOW'S LENGTH IS NOT. One readback is
//! this model's choice, the smallest non-zero window that makes a documented
//! rule observable in an instruction-stepped emulator with no bus clock to
//! count. The page does not say how many cycles the condition takes, so no
//! number is invented here. A driver that waits, which every in-tree one
//! does, sees no change at all.
//!
//! THE WINDOW CLOSES ON ANY LATER TOUCH OF ICCR2, not only the readback the
//! driver spins on. Silicon clears RS once the condition is issued whether or
//! not anybody looks, so a window that outlived the transaction would be a
//! worse invention than the gap it replaced: a driver that never reads ICCR2
//! back would have had every later store swallowed, including the next
//! transaction's address. Requesting any condition retires a standing one.
const flag = @import("flags.zig");

/// One channel's restart window.
pub const Restart = struct {
    /// A restart has been requested and RS has not been read back clear yet.
    pending: bool = false,
    /// Stores to ICDRT made while RS still read 1. Silicon drops them; dev
    /// clocked them out.
    dropped: u32 = 0,

    /// A repeated START was accepted on a busy bus: the condition is in
    /// flight and RS reads 1 until the driver looks.
    pub fn request(self: *Restart) void {
        self.pending = true;
    }

    /// The look the driver spins on. The condition is issued as it happens,
    /// so RS reads 0 from here on. Answers whether it had been standing.
    pub fn observe(self: *Restart) bool {
        const was_pending = self.pending;
        self.pending = false;
        return was_pending;
    }

    /// Whether an ICDRT store right now carries nothing.
    pub fn blocks(self: *const Restart) bool {
        return self.pending;
    }

    /// Count a store the window swallowed.
    pub fn note(self: *Restart) void {
        self.dropped +%= 1;
    }

    /// The bits RS occupies, cleared out of a shadow byte.
    pub fn without(value: u8) u8 {
        return value & ~flag.iccr2.rs;
    }

    /// A reset closes the window; the run's record of it stays.
    pub fn clear(self: *Restart) void {
        self.pending = false;
    }

    pub fn quiet(self: *const Restart) bool {
        return self.dropped == 0;
    }
};
