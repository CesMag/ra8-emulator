//! How far the RTC moves at a chunk boundary.
//!
//! `boundary` is the geared clock the corpus was recorded on: one second
//! and one R64CNT step per boundary, whatever the virtual time. `virtual`
//! counts the virtual nanoseconds the time base reports, so the date and
//! time firmware reads match the run at any speed. A run fits its board
//! with the virtual clock (RA8EMU-185, board_fit.zig); a bare `Rtc.init()`
//! keeps the boundary gear so the RTC's own tests stay one second a tick.
const std = @import("std");

pub const ns_per_second: u64 = 1_000_000_000;

/// R64CNT's rate: the 64 Hz sub-second count.
pub const r64_hz: u64 = 64;

pub const Mode = enum { boundary, virtual };

/// What one boundary owes the counters.
pub const Owed = struct {
    seconds: u64,
    r64: u64,
};

/// The running clock's virtual time and the gear it moves in.
pub const Pace = struct {
    mode: Mode = .boundary,
    /// Virtual nanoseconds counted while the clock ran. The sub-second
    /// part is the carry the next boundary builds on.
    run_ns: u64 = 0,

    /// What a boundary `elapsed_ns` after the last one owes. A geared
    /// clock ignores the time and owes `boundary_seconds`.
    pub fn step(self: *Pace, elapsed_ns: u64, boundary_seconds: u8) Owed {
        if (self.mode == .boundary) return .{ .seconds = boundary_seconds, .r64 = 1 };
        const before = self.run_ns;
        self.run_ns +%= elapsed_ns;
        return .{
            .seconds = self.run_ns / ns_per_second -% before / ns_per_second,
            .r64 = r64Count(self.run_ns) -% r64Count(before),
        };
    }
};

/// Whole R64CNT steps in `ns`.
pub fn r64Count(ns: u64) u64 {
    return @intCast(@as(u128, ns) * r64_hz / ns_per_second);
}
