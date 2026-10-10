//! The controller receive path: what the addressed device staged for this
//! read, and the reads that take it back out one byte at a time.
//!
//! The flow does one dummy ICDRR read to start the data clock before the
//! first real byte (HUM Ch 39.3.4 "Controller Receive Operation", p 2400 and
//! Ch 39.2.18 "ICDRR", p 2393), so the first access after the address phase
//! carries nothing. RDRF stands while a byte is waiting and goes away with
//! the last one.
//!
//! A part that stretches the clock (RA8EMU-532) makes each byte land a
//! virtual deadline after the last: RDRF only reads back once the board's
//! time base has passed it. Without a clock or a stretch the deadline is
//! zero and nothing waits.
const flag = @import("flags.zig");
const timebase = @import("../time/timebase.zig");

/// How much of a device's answer one transfer can hold.
pub const stage_bytes = 64;

pub const Rx = struct {
    /// What the addressed device staged for this read.
    staged: [stage_bytes]u8 = @splat(0),
    staged_len: usize = 0,
    served: usize = 0,
    /// The dummy read that starts the clock has not happened yet.
    primed: bool = false,

    /// Reads past what the device had to say. dev served zeros, so a driver
    /// reading too far got data that looked real.
    overread: u32 = 0,

    /// The board's virtual time; set once by the board's wiring.
    clock: ?*const timebase.TimeBase = null,
    /// How long the addressed part stretches each byte, and when the next
    /// one lands.
    stretch_ns: u64 = 0,
    due_ns: u64 = 0,
    /// ICDRR reads made before the stretched byte landed, so with RDRF
    /// still clear. The byte stays put for the read that waits.
    early: u32 = 0,

    /// A STOP request terminates the receive frame after its in-flight byte.
    /// Devices may expose more data than the controller asked to clock; those
    /// bytes are not pending bus traffic once the controller requests STOP.
    pub fn stopAfterNext(self: *Rx) void {
        self.staged_len = @min(self.staged_len, self.served + 1);
    }

    /// Start a frame empty: nothing staged, nothing served, clock not yet
    /// running.
    pub fn open(self: *Rx) void {
        self.staged_len = 0;
        self.served = 0;
        self.primed = false;
    }

    /// Take what the device has to say for this frame.
    pub fn stage(self: *Rx, len: usize, stretch_ns: u64) void {
        self.staged_len = len;
        self.served = 0;
        self.primed = false;
        self.stretch_ns = stretch_ns;
        self.due_ns = self.now() + stretch_ns;
    }

    fn now(self: *const Rx) u64 {
        const clock = self.clock orelse return 0;
        return clock.now();
    }

    /// The stretched byte has landed, or nothing is stretching.
    /// With no clock there is no time to wait for, so it always has.
    pub fn landed(self: *const Rx) bool {
        const clock = self.clock orelse return true;
        return clock.now() >= self.due_ns;
    }

    /// ICSR2 as the driver sees it: RDRF waits for the byte to land.
    pub fn visible(self: *const Rx, status: u8) u8 {
        return if (self.landed()) status else status & ~flag.icsr2.rdrf;
    }

    /// A byte is still waiting to be handed over.
    pub fn holding(self: *const Rx) bool {
        return self.served < self.staged_len;
    }

    /// The next ICDRR access. `status` is the channel's ICSR2, since RDRF
    /// moves with the data. Answers null when the access was the dummy read
    /// that only starts the clock.
    pub fn take(self: *Rx, status: *u8) ?u8 {
        if (!self.primed) {
            self.primed = true;
            return null;
        }
        if (!self.holding()) {
            // Nothing left on the line. RDRF goes away with the data.
            self.overread += 1;
            status.* &= ~flag.icsr2.rdrf;
            return null;
        }
        if (!self.landed()) {
            self.early += 1;
            return null;
        }
        const byte = self.staged[self.served];
        self.served += 1;
        self.due_ns = self.now() + self.stretch_ns;
        if (self.holding()) {
            status.* |= flag.icsr2.rdrf;
        } else {
            status.* &= ~flag.icsr2.rdrf;
        }
        return byte;
    }

    pub fn quiet(self: *const Rx) bool {
        return self.overread == 0 and self.early == 0;
    }
};
