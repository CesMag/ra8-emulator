//! When each core's SysTick next wraps, in virtual nanoseconds
//! (RA8EMU-515, slice 3).
//!
//! A SysTick tick is a core clock cycle, and each core is clocked through
//! its own SCKDIVCR2 nibble, so the same CVR wraps at different times on
//! CPU0 and CPU1. A counter reaches zero on its CVR-th tick, or a full
//! period (RVR + 1 ticks) after it was left at zero (clocks.wrap,
//! RA8EMU-657), and that tick ends ticks * 1e9 / hz ns from now. The answer is rounded up to
//! the first whole nanosecond the wrap has happened by, the same instant
//! TimeBase.cyclesUntil counts to.
//!
//! The run already charges each core's SysTick its own instructions, and
//! CPU1's turn is sized by core_rate.turn, so this is a reading of where the
//! wrap falls, not a second clock: nothing here moves a counter or touches
//! the event queue.
const clocks = @import("../clocks.zig");
const rate = @import("../sysclk/rate.zig");

const ns_per_s: u64 = 1_000_000_000;

/// The three SysTick words that decide the next wrap.
pub const Counter = struct { csr: u32, rvr: u32, cvr: u32 };

/// The virtual ns of the next wrap of a counter on a core clocked at `hz`,
/// or null when it never wraps (disabled, a zero reload) or the rate is
/// unknown.
pub fn dueNs(counter: Counter, now_ns: u64, hz: u64) ?u64 {
    if (counter.csr & clocks.csr_enable == 0) return null;
    if (counter.rvr & clocks.counter_mask == 0) return null;
    if (hz == 0) return null;
    const cvr: u64 = counter.cvr & clocks.counter_mask;
    const ticks: u64 = if (cvr != 0) cvr else @as(u64, counter.rvr & clocks.counter_mask) + 1;
    return now_ns + divCeil(ticks * ns_per_s, hz);
}

/// The same, for `core` clocked from the tree `inputs` describes.
pub fn coreDueNs(inputs: rate.Inputs, core: rate.Core, counter: Counter, now_ns: u64) ?u64 {
    return dueNs(counter, now_ns, rate.coreHz(inputs, core) orelse return null);
}

fn divCeil(a: u64, b: u64) u64 {
    return a / b + @intFromBool(a % b != 0);
}
