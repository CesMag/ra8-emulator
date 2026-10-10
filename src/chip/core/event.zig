//! The two cores' event registers, the state WFE and SEV meet on
//! (RA8EMU-36).
//!
//! Armv8-M gives every PE one event bit. SEV sets it on every PE in the
//! system, the one that ran it included. WFE consumes the bit when it is set
//! and carries on; when it is clear the PE waits until something sets it.
//! Exception entry and return set the local bit, and so does an interrupt
//! becoming pending when SCR.SEVONPEND is on. That is the whole contract a
//! dual-core handshake leans on: CPU1 parks in WFE, CPU0 posts to the mailbox
//! and runs SEV, CPU1 wakes and reads it.
//!
//! This is the model only. Which instruction ran and when is the run loop's
//! business, so the same state serves both engine backends.
const std = @import("std");

pub const cores = 2;
pub const Core = u1;

/// What a WFE does on a core.
pub const Outcome = enum {
    /// The bit was set: it is consumed and the core carries on.
    proceeds,
    /// The bit was clear: the core waits for an event.
    waits,
};

pub const Events = struct {
    bits: [cores]bool = .{ false, false },
    waiting: [cores]bool = .{ false, false },

    /// SEV on any core: every core's bit is set and every waiter wakes.
    pub fn sev(self: *Events) void {
        for (0..cores) |index| self.post(@intCast(index));
    }

    /// An event local to one core: exception entry or return, or a pending
    /// interrupt with SEVONPEND set.
    pub fn post(self: *Events, core: Core) void {
        if (self.waiting[core]) {
            self.waiting[core] = false;
            return;
        }
        self.bits[core] = true;
    }

    /// WFE on `core`.
    pub fn wfe(self: *Events, core: Core) Outcome {
        if (self.bits[core]) {
            self.bits[core] = false;
            return .proceeds;
        }
        self.waiting[core] = true;
        return .waits;
    }

    /// Whether `core` is parked in a WFE no event has ended yet.
    pub fn parked(self: *const Events, core: Core) bool {
        return self.waiting[core];
    }
};

comptime {
    std.debug.assert(std.math.maxInt(Core) + 1 == cores);
}
