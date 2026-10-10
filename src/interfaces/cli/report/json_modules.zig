//! The clock-generation half of the `clocks` object (RA8EMU-355): clock
//! selects, dividers, oscillators, the sub-clock, the MRAM clocks and the
//! module-stop verdict, the same facts report/modules.zig prints. Lists hold
//! only the selects and dividers the firmware touched.
const Board = @import("ra8_board").board.Board;
const ckcr = @import("ra8_chip").periph.ckcr;
const ckdiv = @import("ra8_chip").periph.ckdiv;

/// Written inside the `clocks` object, after the monitors.
pub fn parts(j: anytype, board: *Board) !void {
    try selects(j, board);
    try dividers(j, board);
    try oscillators(j, board);
    try subClock(j, board);
    try memoryRates(j, board);
    try moduleStop(j, board);
}

fn selects(j: anytype, board: *Board) !void {
    const unit = &board.branches;
    try j.open("selects", '{');
    try j.field("dropped_locked", unit.dropped_locked);
    try j.open("branches", '[');
    for (&unit.selects, 0..) |*one, index| {
        if (one.requests == 0 and one.switches == 0) continue;
        try j.open(null, '{');
        try j.field("name", ckcr.slots[index].name);
        try j.field("requests", one.requests);
        try j.field("switches", one.switches);
        try j.field("source", one.sel);
        try j.close('}');
    }
    try j.close(']');
    try j.close('}');
}

fn dividers(j: anytype, board: *Board) !void {
    const unit = &board.ratios;
    try j.open("dividers", '{');
    try j.field("dropped_locked", unit.dropped_locked);
    try j.open("branches", '[');
    for (&unit.dividers, 0..) |*one, index| {
        if (one.writes == 0 and one.ungated == 0) continue;
        try j.open(null, '{');
        try j.field("name", ckdiv.slots[index].name);
        try j.field("code", one.value());
        try j.field("writes", one.writes);
        try j.field("ungated", one.ungated);
        try j.close('}');
    }
    try j.close(']');
    try j.close('}');
}

fn oscillators(j: anytype, board: *Board) !void {
    const unit = &board.oscillators;
    try j.open("oscillators", '{');
    try j.field("starts", unit.starts);
    try j.field("stops", unit.stops);
    try j.field("oscsf", unit.flags());
    try j.field("refused_flag_stores", unit.readonly_writes);
    try j.field("dropped_locked", unit.dropped_locked);
    try j.close('}');
}

fn subClock(j: anytype, board: *Board) !void {
    const unit = &board.subclk;
    try j.open("sub_clock", '{');
    try j.field("running", unit.running());
    try j.field("drive", unit.drive().name());
    try j.field("starts", unit.starts);
    try j.field("refused_running", unit.refused_running);
    try j.field("dropped_locked", unit.dropped_locked);
    try j.close('}');
}

fn memoryRates(j: anytype, board: *Board) !void {
    const unit = &board.memory_rates;
    try j.open("memory_rates", '{');
    try j.field("mriclk_mhz", unit.code.mhz);
    try j.field("mrpclk_mhz", unit.extra.mhz);
    try j.field("prefetch_on", unit.prefetching());
    try j.field("refused_keys", unit.code.refused + unit.extra.refused);
    try j.field("hot_changes", unit.hot_changes);
    try j.field("early_enables", unit.early_enables);
    try j.close('}');
}

fn moduleStop(j: anytype, board: *Board) !void {
    const verdict = board.modules.verdict();
    try j.open("module_stop", '{');
    try j.field("clean", board.modules.clean());
    try j.field("stopped_reads", verdict.stopped_reads);
    try j.field("stopped_writes", verdict.stopped_writes);
    try j.field("last_stopped", verdict.last_stopped);
    try j.field("probed_reads", verdict.probed_reads);
    try j.field("probed_writes", verdict.probed_writes);
    try j.field("last_probed", verdict.last_probed);
    try j.close('}');
}
