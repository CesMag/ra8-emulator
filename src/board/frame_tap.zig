//! The frame tap: a passive per-boundary capture hook (RA8EMU milestone M7).
//!
//! It runs once per boundary, after the board's tick. It is never a grid
//! edge and never arms the panel's frame clock: the clock is the run's
//! `panel_vsync` config, and a consumer captures through the tap only when
//! the config has armed no edges to ride. Captures are rate-capped in host
//! time, so a run at `max` speed does not composite at every boundary.
//!
//! What the tap does with a capture (change-trigger or not) is the
//! consumer's own business; the tap only decides when one may happen.
const std = @import("std");

pub const Tap = struct {
    io: std.Io,
    context: *anyopaque,
    captureFn: *const fn (context: *anyopaque, virtual_ns: u64) void,
    /// Host nanoseconds between captures.
    interval_ns: i96 = 16_666_667,
    last_ns: i96 = 0,

    /// One boundary has passed. Capture, unless the host rate cap says not yet.
    pub fn afterBoundary(self: *Tap, virtual_ns: u64) void {
        const now = std.Io.Timestamp.now(self.io, .real).toNanoseconds();
        if (self.last_ns != 0 and now - self.last_ns < self.interval_ns) return;
        self.captureFn(self.context, virtual_ns);
        self.last_ns = std.Io.Timestamp.now(self.io, .real).toNanoseconds();
    }
};

/// Multi-subscriber fan-out for passive frame taps.
pub const FanOut = struct {
    pub const max_subscribers = 4;
    subscribers: [max_subscribers]?*Tap = .{ null, null, null, null },

    pub fn add(self: *FanOut, tap: *Tap) bool {
        for (&self.subscribers) |*slot| {
            if (slot.* == tap) return true;
        }
        for (&self.subscribers) |*slot| {
            if (slot.* == null) {
                slot.* = tap;
                return true;
            }
        }
        return false;
    }

    pub fn remove(self: *FanOut, tap: *Tap) void {
        for (&self.subscribers) |*slot| {
            if (slot.* == tap) {
                slot.* = null;
                return;
            }
        }
    }

    pub fn contains(self: *const FanOut, tap: *const Tap) bool {
        for (self.subscribers) |slot| {
            if (slot == tap) return true;
        }
        return false;
    }

    pub fn first(self: *const FanOut) ?*Tap {
        for (self.subscribers) |slot| {
            if (slot) |t| return t;
        }
        return null;
    }

    pub fn count(self: *const FanOut) usize {
        var n: usize = 0;
        for (self.subscribers) |slot| {
            if (slot != null) n += 1;
        }
        return n;
    }

    pub fn isEmpty(self: *const FanOut) bool {
        return self.first() == null;
    }

    pub fn afterBoundary(self: *FanOut, virtual_ns: u64) void {
        for (self.subscribers) |maybe_tap| {
            if (maybe_tap) |tap| tap.afterBoundary(virtual_ns);
        }
    }
};
