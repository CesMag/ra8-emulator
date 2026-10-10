//! How fast WDT0 counts, in run-loop ticks per watchdog count.
//!
//! The firmware measured it, so this model takes the bench's number rather
//! than the manual's. examples/ek_ra8d2/hw_validated/hil/wdt_window_demo/
//! src/main.c records it next to its window bounds: "the WWDT counts on a
//! ~40 Hz base clock (chip's WDT clock source -- not PCLKB despite the HUM
//! nomenclature), so the 1024-cycle period runs ~25 s", with CKS at /4.
//! wdt_supervisor_demo programmes the same TOPS and CKS and refreshes every
//! 50 ms, so on the bench it never comes near underflow.
//!
//! The model before this counted one watchdog cycle per 3906 instructions,
//! dev's 128 cycles per 500000-instruction chunk, which made that 25 s
//! period about 4 ms and had the supervisor underflow after every refresh.
//!
//! The divider still scales the rate: ra8_wdt.h names CKS a divider of the
//! counter's clock, and the bench figure is the /4 point of it. That other
//! dividers scale from /4 the way their names say is the manual's claim, not
//! a bench reading, and is the one inference here.
const cadence = @import("../../core/cadence.zig");
const timebase = @import("../time/timebase.zig");

/// Virtual ns one run-loop tick (a full chunk boundary) stands for on the
/// time base. A due time built from it lands on the very boundary the
/// per-tick pacing fires on, so moving the watchdogs onto the event queue
/// (RA8EMU-179, slice RA8EMU-514) leaves the corpus where it is.
pub const ns_per_tick: u64 = @as(u64, cadence.instructions) * timebase.ns_per_s / timebase.default_hz;

/// The event-queue ids the two watchdogs schedule their underflow under,
/// and the WDT its next refresh-window edge (RA8EMU-587).
pub const queue_id = struct {
    pub const wdt: u16 = 0x0B00;
    pub const iwdt: u16 = 0x0B01;
    pub const wdt_window: u16 = 0x0B02;
};

/// Whole run-loop ticks in `elapsed_ns`, the leftover carried in `carry`
/// so a run of short (narrowed) boundaries adds up to the ticks one long
/// boundary would have counted.
pub fn ticksIn(carry: *u64, elapsed_ns: u64) u64 {
    const total = carry.* + elapsed_ns;
    carry.* = total % ns_per_tick;
    return total / ns_per_tick;
}

/// The bench reading, and the divider it was taken at.
pub const bench = struct {
    pub const counts_per_second: u32 = 40;
    pub const divider: u32 = 4;
};

/// Modelled instructions per second: src/interfaces/cli/cli.zig budgets
/// 1_000_000 instructions per millisecond.
pub const instructions_per_second: u64 = 1_000_000_000;

/// CKS[3:0] to its divider. ra8_wdt.h lists the six legal encodings
/// (HUM Ch 27.2.2 p 1258); the rest are "setting prohibited" and count at
/// the bench rate, which is also what an unprogrammed CKS of zero gets.
pub fn divider(cks: u4) u32 {
    return switch (cks) {
        0x1 => 4,
        0x4 => 64,
        0xF => 128,
        0x6 => 512,
        0x7 => 2048,
        0x8 => 8192,
        else => bench.divider,
    };
}

/// Run-loop ticks between two watchdog counts at this divider.
pub fn ticksPerCount(cks: u4) u32 {
    const per_count = instructions_per_second * divider(cks) /
        (@as(u64, bench.counts_per_second) * bench.divider);
    return @intCast(@max(1, per_count / cadence.instructions));
}
