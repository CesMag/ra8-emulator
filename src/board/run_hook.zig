//! What the board tells a run's policy (RA8EMU-1047). Host-clock pacing and
//! what ends a soak sit above the board (ADR 0004): the board only says when
//! a boundary closed and when a watchdog reset it, and whoever runs it
//! decides what that means. With no hook a boundary pays nothing extra.
pub const Reset = enum { watchdog, iwdt };

pub const RunHook = struct {
    context: *anyopaque,
    boundaryFn: *const fn (*anyopaque, u64) void,
    resetFn: *const fn (*anyopaque, Reset, u64) void,
};
