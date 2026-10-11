//! One virtual time for the whole machine (RA8EMU-179, slice RA8EMU-511).
//!
//! Time is retired CPU0 cycles at the core's rate. It is kept as cycles and
//! a rate, and nanoseconds are worked out from those two on every read, so a
//! week-long soak adds no rounding at all at a fixed rate. A rate change
//! folds what has gone by into whole nanoseconds and starts counting again,
//! which loses under one nanosecond per change.
//!
//! Until the clock tree feeds the rate (RA8EMU-515), it is the part's CPU0
//! ceiling, 1 GHz (core/part/clock.zig). Normal runs charge one cycle per
//! instruction; the `--ms` boundary scales its fixed instruction cadence into
//! cycles at the selected rate.
pub const ns_per_s: u64 = 1_000_000_000;

/// CPU0's maximum clock on both modelled parts (RA8D2 Table 1.14, RA8P1
/// Table 1.15).
pub const default_hz: u64 = 1_000_000_000;

pub const TimeBase = struct {
    /// Whole nanoseconds that went by before the current rate took effect.
    base_ns: u64 = 0,
    /// Cycles counted at the current rate.
    cycles: u64 = 0,
    /// Every cycle this run retired, across rate changes.
    retired: u64 = 0,
    hz: u64 = default_hz,

    pub fn advance(self: *TimeBase, cycles: u64) void {
        self.cycles += cycles;
        self.retired += cycles;
    }

    /// Virtual nanoseconds since the run started.
    pub fn now(self: *const TimeBase) u64 {
        return self.base_ns + toNs(self.cycles, self.hz);
    }

    /// Switch the rate from here on. A zero rate is ignored rather than
    /// stopping time.
    pub fn setRate(self: *TimeBase, hz: u64) void {
        if (hz == 0 or hz == self.hz) return;
        self.base_ns = self.now();
        self.cycles = 0;
        self.hz = hz;
    }

    /// Cycles at the current rate until `at_ns` has been reached; zero when
    /// it already has.
    pub fn cyclesUntil(self: *const TimeBase, at_ns: u64) u64 {
        const at = self.now();
        if (at_ns <= at) return 0;
        // The first cycle count whose time is at or past at_ns.
        const target = at_ns - self.base_ns;
        const whole = target / ns_per_s;
        const rest = target % ns_per_s;
        const needed = whole * self.hz + divCeil(rest * self.hz, ns_per_s);
        return needed - self.cycles;
    }
};

/// cycles * 1e9 / hz, rounded down, without overflowing on a long run.
pub fn toNs(cycles: u64, hz: u64) u64 {
    const whole = cycles / hz;
    const rest = cycles % hz;
    return whole * ns_per_s + rest * ns_per_s / hz;
}

fn divCeil(a: u64, b: u64) u64 {
    return (a + b - 1) / b;
}
