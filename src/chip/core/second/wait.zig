//! CPU1 parked in WFE (RA8EMU-36).
//!
//! A second core that runs WFE with no event standing waits, and its turns
//! are spent doing nothing: time still passes for it, so its SysTick keeps
//! counting, but none of its instructions run. It wakes when:
//!
//! - an exception is taken on it (exception entry is an event), or
//! - the other core runs SEV, or
//! - it has idled `limits.spurious_after` turns. Armv8-M lets a WFE
//!   complete for no architectural reason at all, and firmware loops around
//!   it for exactly that, so this is a legal wake. It covers events the
//!   model cannot see, such as a SEV CPU1 itself ran before its WFE.
//!
//! src/chip/core/second/core.zig routes a WFE stop here.
const core_event = @import("../event.zig");

pub const limits = struct {
    /// Idle turns before a parked core wakes on its own.
    pub const spurious_after: u32 = 16;
};

/// The second core's index in `core_event.Events`.
const cpu1: core_event.Core = 1;

pub const Wait = struct {
    events: core_event.Events = .{},
    /// Turns spent parked since the last wake.
    idle_turns: u32 = 0,
    /// WFEs that parked the core.
    parks: usize = 0,
    wakes: Wakes = .{},

    pub const Wakes = struct {
        interrupt: usize = 0,
        event: usize = 0,
        spurious: usize = 0,
    };

    pub fn parked(self: *const Wait) bool {
        return self.events.parked(cpu1);
    }

    /// The other core ran SEV.
    pub fn sev(self: *Wait) void {
        const was = self.parked();
        self.events.sev();
        if (was and !self.parked()) self.wakes.event += 1;
    }

    /// The core ran a WFE. True when it parks, false when a standing event
    /// let it straight through.
    pub fn arrive(self: *Wait) bool {
        if (self.events.wfe(cpu1) == .proceeds) return false;
        self.parks += 1;
        self.idle_turns = 0;
        return true;
    }

    /// One parked turn has passed; `entered` is whether an exception was
    /// taken on the core at its boundary.
    pub fn idled(self: *Wait, entered: bool) void {
        if (entered) {
            self.wakes.interrupt += 1;
            self.events.post(cpu1);
            return;
        }
        self.idle_turns += 1;
        if (self.idle_turns < limits.spurious_after) return;
        self.wakes.spurious += 1;
        self.events.post(cpu1);
    }
};
