//! ICCR2.SP asked for mid-frame is a request, not an instant end (HUM Ch
//! 39.3.4 "Controller Receive Operation", p 2400).
//!
//! The controller receive sequence arms its end-of-frame controls off a
//! bytes-remaining countdown: WAIT at three to go, the NACK at two, and the
//! STOP at one. The STOP is asked for BEFORE the last byte has been taken,
//! which only works because it is a request: the condition physically fires
//! after the final ICDRR read and the WAIT clear that lets the clock run on.
//! ra8_i2c.c's internal_i2c_drain_rx says so in as many words, and gives the
//! reason: waiting for BBSY before reading the last byte would deadlock.
//!
//! dev ended the transaction on the SP store itself. So the device was told
//! the transaction had finished while it still had a byte to hand over, the
//! run counted the transfer before the driver had it, and BBSY answered clear
//! straight away, which is the one thing the driver's own comment says cannot
//! happen. A driver that reads BBSY and opens the next transaction on the
//! strength of it is served here and finds the bus still held on silicon.
//!
//! WHAT HOLDS THE STOP: a byte still staged for the frame, or ICMR3.WAIT
//! still holding the clock. Either one defers it; the condition fires on
//! whichever access clears the last of them, which for the driver's own
//! sequence is the ICMR3 store that drops WAIT and ACKBT together. A stop
//! asked for with nothing holding it fires at once, the way it always did.
pub const Stop = struct {
    /// A condition asked for and not yet fired.
    pending: bool = false,

    /// Stops that had to wait for the frame to finish. dev fired every one
    /// of them early.
    deferred: u32 = 0,

    /// Take the request. Answers true when the condition has to wait, so the
    /// caller leaves the transaction open.
    pub fn request(self: *Stop, held: bool) bool {
        if (!held) return false;
        self.pending = true;
        self.deferred +%= 1;
        return true;
    }

    /// Answers true on the access that lets a waiting condition fire.
    pub fn release(self: *Stop, held: bool) bool {
        if (!self.pending or held) return false;
        self.pending = false;
        return true;
    }

    pub fn clear(self: *Stop) void {
        self.pending = false;
    }

    pub fn quiet(self: *const Stop) bool {
        return self.deferred == 0;
    }
};
