//! The `timers` object of `--report json` (RA8EMU-356): the low-power
//! timers, the AGTs, the GPT channels and the GPT bank, the same facts
//! report/timers.zig prints. The watchdogs and the RTC follow in
//! json_watch.zig. Every key is always present; channel lists hold only the
//! channels that did anything.
const Board = @import("ra8_board").board.Board;
const json_watch = @import("json_watch.zig");

/// The whole `timers` object, keyed inside the document.
pub fn section(j: anytype, board: *Board) !void {
    try j.open("timers", '{');
    try lowPower(j, board);
    try interval(j, board);
    try pwm(j, board);
    try bank(j, board);
    try json_watch.parts(j, board);
    try j.close('}');
}

fn lowPower(j: anytype, board: *Board) !void {
    try j.open("ulpt", '[');
    for (&board.lowpower.channels, 0..) |*channel, index| {
        const pair = &channel.compares;
        if (channel.underflows == 0 and !channel.running() and pair.quiet()) continue;
        try j.open(null, '{');
        try j.field("index", index);
        try j.field("counter", channel.counter);
        try j.field("underflows", channel.underflows);
        try j.field("divider", channel.divider());
        try j.field("running", channel.running());
        try j.field("forced_stops", channel.forced_stops);
        try j.field("compare_a", pair.a);
        try j.field("matches_a", pair.matches_a);
        try j.field("compare_b", pair.b);
        try j.field("matches_b", pair.matches_b);
        try j.close('}');
    }
    try j.close(']');
}

fn interval(j: anytype, board: *Board) !void {
    try j.open("agt", '[');
    for (&board.interval.channels, 0..) |*channel, index| {
        if (channel.quiet()) continue;
        try j.open(null, '{');
        try j.field("index", index);
        try j.field("counter", channel.counter);
        try j.field("reload", channel.reload);
        try j.field("underflows", channel.underflows);
        try j.field("running", channel.running());
        try j.field("matches_a", channel.matches_a);
        try j.field("matches_b", channel.matches_b);
        try j.field("masked_crossings", channel.masked);
        try j.field("forced_stops", channel.forced_stops);
        try j.field("refused_running", channel.refused_running);
        try j.field("lost_cascade", channel.dropped_cascade);
        try j.close('}');
    }
    try j.close(']');
}

fn pwm(j: anytype, board: *Board) !void {
    try j.open("gpt", '[');
    for (&board.pwm.channels, 0..) |*channel, index| {
        if (channel.quiet()) continue;
        const now = channel.shape();
        const log = channel.shapes;
        const pair = &channel.compares;
        const parked = &channel.period;
        try j.open(null, '{');
        try j.field("index", index);
        try j.field("gtcnt", channel.cnt);
        try j.field("period", channel.periodOrDefault());
        try j.field("mode", now.name());
        try j.field("first_mode", if (log.overwritten(now)) if (log.first) |first| first.name() else null else null);
        try j.field("mode_changes", log.changes);
        try j.field("overflows", channel.overflows);
        try j.field("running", channel.running());
        try j.field("source", channel.source().name());
        try j.field("compare_writes", pair.writes);
        try j.field("compare_a", pair.value(.a));
        try j.field("matches_a", pair.matches(.a));
        try j.field("compare_b", pair.value(.b));
        try j.field("matches_b", pair.matches(.b));
        try j.field("period_parked", parked.parked);
        try j.field("gtpbr", parked.buffer);
        try j.field("period_loads", parked.loads);
        try j.field("period_changes", parked.changes);
        try j.field("refused_protected", channel.guard.refused);
        try j.close('}');
    }
    try j.close(']');
}

fn bank(j: anytype, board: *Board) !void {
    const clock = &board.gpt_clock;
    const state = &board.pwm.sync;
    try j.open("gpt_bank", '{');
    try j.field("gtclk_programmed", clock.programmed());
    try j.field("prohibited_running", clock.prohibited_running);
    try j.field("bits_acted", state.acted);
    try j.field("stores_together", state.together);
    try j.field("absent_channels", state.absent);
    try j.field("stray_stores", state.stray);
    try j.close('}');
}
