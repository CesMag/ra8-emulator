//! The watchdog and RTC half of the `timers` object (RA8EMU-356): IWDT,
//! WDT0 and the RTC, the same facts report/timers.zig (IWDT),
//! report/watchdog.zig and report/time.zig print. WDT0's refresh cadence
//! needs a SysTick timebase this section does not carry; a reader divides the
//! timing section's ticks by `refreshes` instead.
const Board = @import("ra8_board").board.Board;
const iwdt = @import("ra8_chip").periph.iwdt;

/// Written inside the `timers` object, after the GPT bank.
pub fn parts(j: anytype, board: *Board) !void {
    try independent(j, board);
    try window(j, board);
    try rtc(j, board);
}

fn independent(j: anytype, board: *Board) !void {
    const unit = &board.heartbeat;
    try j.open("iwdt", '{');
    try j.field("refreshes", unit.refreshes);
    try j.field("counter", unit.counter);
    try j.field("full_scale", iwdt.full_scale);
    try j.field("underflows", unit.underflows);
    try j.field("running", unit.armed);
    try j.field("stopped_by_options", unit.stoppedByOptions());
    try j.field("option_word", unit.option_word);
    try j.field("stopped_refreshes", unit.stopped_refreshes);
    try j.field("dropped_refreshes", unit.dropped);
    try j.field("nmis", unit.nmis);
    try j.field("bad_acks", unit.bad_acks);
    try j.field("frozen_writes", unit.frozen_writes);
    try j.close('}');
}

fn window(j: anytype, board: *Board) !void {
    const unit = &board.watchdog;
    try j.open("wdt0", '{');
    try j.field("refreshes", unit.refreshes);
    try j.field("refused_early", unit.early);
    try j.field("counter", unit.counter);
    try j.field("reload", unit.reload());
    try j.field("underflows", unit.underflows);
    try j.field("bad_acks", unit.bad_acks);
    try j.field("dropped_locked", unit.locked_writes);
    try j.close('}');
}

fn rtc(j: anytype, board: *Board) !void {
    const unit = &board.clock;
    const now = unit.now;
    try j.open("rtc", '{');
    try j.field("year", 2000 + @as(u32, now.year));
    try j.field("month", now.month);
    try j.field("day", now.day);
    try j.field("hour", now.hour);
    try j.field("minute", now.minute);
    try j.field("second", now.second);
    try j.field("seconds_counted", unit.seconds);
    try j.field("alarm_matches", unit.matches);
    try j.field("alarm_events", unit.alarms);
    try j.field("periodic_events", unit.periodics);
    try j.field("refused_running", unit.refused_running);
    try j.field("resets", unit.resets);
    try j.field("refused_read_only", unit.refused_read_only);
    try j.field("count_source", if (unit.count_source.chosen) unit.count_source.source.name() else null);
    try j.field("late_source_stores", unit.count_source.late);
    try j.field("unsourced_resets", unit.count_source.unsourced);
    try j.field("hot_divisor_stores", unit.divisor.hot_stores);
    try j.field("out_of_order_divisor", unit.divisor.out_of_order);
    try j.close('}');
}
