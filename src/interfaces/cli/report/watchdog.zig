//! What the windowed watchdog saw, and how often the firmware fed it.
//!
//! Its own file rather than another section of report.zig for the reason
//! AGENTS.md gives: report.zig had grown past the gate's 400 lines, and the
//! watchdog's account of itself is one thing a reader looks for on its own.
const Board = @import("../../../board/board.zig").Board;
const Writer = @import("../report.zig").Writer;
const clocks = @import("ra8_chip").periph.clocks;

/// The refused refresh is the loud case: on silicon an early reload is a
/// refresh error that resets the part, and the C tree accepts it silently.
pub fn section(board: *Board, out: Writer, timebase: clocks.Clocks) !void {
    const unit = &board.watchdog;
    if (unit.quiet()) return;
    if (unit.early != 0) {
        try out.print("WDT0: refreshes={d} REFUSED={d} (refresh outside the RPSS/RPES window, REFEF latched)\n", .{ unit.refreshes, unit.early });
    } else {
        try out.print("WDT0: refreshes={d}, counter {d}/{d}, underflows={d}\n", .{ unit.refreshes, unit.counter, unit.reload(), unit.underflows });
    }
    try cadence(unit.refreshes, timebase, out);
    if (unit.bad_acks != 0) {
        try out.print("WDT0: {d} ack(s) wrote a one at a flag and cleared nothing (WDTSR is write-zero-to-clear)\n", .{unit.bad_acks});
    }
    if (unit.locked_writes == 0) return;
    try out.print("WDT0: DROPPED {d} control store(s), WDTCR/WDTRCR/WDTCSTPR take one write each after reset\n", .{unit.locked_writes});
}

/// How often the firmware refreshed the watchdog, in the unit the model
/// actually counts.
///
/// WHY A RATE AND NOT JUST A COUNT. A refresh count on its own cannot be
/// judged. A supervisor declares its cadence in milliseconds in its own
/// source, and the only way to check the model against that was to go and
/// read the run length and divide, by hand, every time. Stating the rate
/// here turns the comparison into reading one line.
///
/// Measured on `wdt_supervisor_demo`, which is why this exists:
/// `examples/ek_ra8d2/hw_validated/hil/wdt_supervisor_demo/src/main.c` sets
/// `k_wdt_sup_demo_sup_period_ms = 50` and passes it as the supervisor's
/// `refresh_period_ms`, and its ThreadX tick is 1 kHz, so one refresh every
/// 50 SysTick periods is what the firmware asks for. The run reports 296
/// refreshes over 200 periods, which is one every 0.7, about seventy times
/// too often. That is a real defect and it was sitting in plain sight
/// behind a bare count.
///
/// SysTick periods rather than milliseconds on purpose. A period is a thing
/// this model counts; a millisecond is a thing it would have to infer from
/// a reload the firmware programmed, and saying "ms" for a run whose tick
/// is not 1 kHz would be a quiet lie. A reader comparing against a firmware
/// that declares ms on a 1 kHz tick reads the two as the same number.
pub fn cadence(refreshes: u32, timebase: clocks.Clocks, out: Writer) !void {
    const every = everyPeriods(refreshes, timebase.ticks) orelse return;
    try out.print(
        "WDT0: one refresh every {d:.1} SysTick period(s) over {d} period(s)\n",
        .{ every, timebase.ticks },
    );
}

/// How many SysTick periods went by per refresh, or null when the question
/// has no answer: a run that never refreshed has no cadence, and a run whose
/// SysTick never ran has no period to count in. Separate from the printing
/// so the arithmetic can be pinned on its own, the way report_dma's tally is.
pub fn everyPeriods(refreshes: u32, ticks: u64) ?f64 {
    if (refreshes == 0 or ticks == 0) return null;
    const periods: f64 = @floatFromInt(ticks);
    const count: f64 = @floatFromInt(refreshes);
    return periods / count;
}
