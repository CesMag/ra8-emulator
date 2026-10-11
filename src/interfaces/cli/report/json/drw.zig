//! The drawing-engine and e-paper keys of the `graphics` object of
//! `--report json` (RA8EMU-371): what DRW rasterized, sampled and cached,
//! and what the IT8951 e-ink controller loaded and refreshed, the same facts
//! report/graphics.zig prints in raster() and panel(). Every key is always
//! present, zero or null on a run that never touched the block.
const Board = @import("ra8_board").board.Board;

/// The `drw` and `eink` keys, written inside `graphics`.
pub fn parts(j: anytype, board: *Board) !void {
    try drw(j, &board.raster);
    try eink(j, &board.panel);
}

fn drw(j: anytype, unit: anytype) !void {
    try j.open("drw", '{');
    try j.field("renders", unit.renders);
    try j.field("last_width", unit.last_width);
    try j.field("last_height", unit.last_height);
    try j.field("pixels", unit.pixels);
    try j.field("limited", unit.limited);
    try j.field("clipped", unit.clipped);
    try j.field("hard_edges", unit.hard_edges);
    try j.field("display_lists", unit.dlists);
    try j.field("display_list_stops", unit.dlist_stops);
    try j.field("declined", unit.declined);
    try j.field("last_decline", if (unit.last_decline) |why| @tagName(why) else null);
    try j.field("faults", unit.faults);
    try j.field("dropped_unpowered", unit.dropped_unpowered);
    try j.field("dark_reads", unit.dark_reads);
    const source = &unit.texture;
    try j.open("texture", '{');
    try j.field("texels", source.texels);
    try j.field("keyed", source.keyed);
    try j.field("wrapped", source.wrapped);
    try j.field("refused_off_ram", source.off_ram);
    try j.field("faults", source.faults);
    try j.close('}');
    try cache(j, &unit.pixel_cache);
    try j.close('}');
}

fn cache(j: anytype, fb: anytype) !void {
    try j.open("cache", '{');
    try j.field("held", fb.held);
    try j.field("written_back", fb.written_back);
    try j.field("flushes", fb.flushes);
    try j.field("evicted", fb.evicted);
    try j.field("forwarded", fb.forwarded);
    try j.field("still_held", if (fb.dirty()) fb.used else 0);
    try j.field("disabled_dirty", fb.disabled_dirty);
    try j.field("faults", fb.faults);
    try j.close('}');
}

fn eink(j: anytype, unit: anytype) !void {
    try j.open("eink", '{');
    try j.field("commands", unit.commands);
    try j.field("pixels", unit.pixels);
    try j.field("refreshes", unit.refreshes);
    try j.field("last_waveform", unit.last_waveform);
    try j.field("vcom_mv", unit.vcom_mv);
    try j.field("awake", unit.awake);
    try j.field("refused_asleep", unit.asleep);
    try j.field("refused_overrun", unit.overrun);
    try j.field("load_width", unit.load_width);
    try j.field("load_height", unit.load_height);
    try j.field("overdrain", unit.overdrain);
    try j.field("stray", unit.stray);
    try j.field("read_only_writes", unit.read_only);
    try j.field("spilled", unit.spilled);
    const lut = &unit.film;
    try j.open("film", '{');
    try j.field("started", lut.started);
    try j.field("settled", lut.settled);
    try j.field("busy_polls", lut.waited);
    try j.field("idle_polls", lut.cleared);
    try j.field("unsettled", lut.unsettled());
    try j.field("overlapped", lut.overlapped);
    try j.close('}');
    try j.close('}');
}
