//! The `clocks` object of `--report json` (RA8EMU-355): the system clock
//! tree, both PLLs, the core voltage range, the low-power mode and the
//! voltage monitors, the same facts sysclk.zig, pll.zig, voltage.zig,
//! lowpower.zig and monitors.zig print. The clock-generation blocks from
//! modules.zig follow in json_modules.zig. Every key is always present.
const Board = @import("ra8_board").board.Board;
const div = @import("ra8_chip").periph.sysclk_div;
const lvd = @import("ra8_chip").periph.lvd;
const Config = @import("ra8_chip").periph.pll_config.Config;
const json_modules = @import("json_modules.zig");

/// The whole `clocks` object, keyed inside the document.
pub fn section(j: anytype, board: *Board) !void {
    try j.open("clocks", '{');
    try system(j, board);
    try plls(j, board);
    try voltage(j, board);
    try lowPower(j, board);
    try monitors(j, board);
    try json_modules.parts(j, board);
    try j.close('}');
}

fn system(j: anytype, board: *Board) !void {
    const unit = &board.tree;
    try j.open("system", '{');
    try j.field("source", unit.source().name());
    try j.field("programmed", unit.programmed);
    try j.field("dropped_locked", unit.dropped_locked);
    try j.field("unstable_selects", unit.unstable_selects);
    try j.field("reserved_selects", unit.reserved_selects);
    try j.open("domains", '[');
    for (div.domains) |domain| try one(j, domain.name, unit.ratioOf(domain), div.codeAt(unit.divcr, domain.at));
    for (div.domains2) |domain| try one(j, domain.name, unit.ratioOf2(domain), div.codeAt(unit.divcr2, domain.at));
    try j.close(']');
    try j.close('}');
}

fn one(j: anytype, name: []const u8, ratio: ?u32, code: u4) !void {
    try j.open(null, '{');
    try j.field("name", name);
    try j.field("ratio", ratio);
    try j.field("code", code);
    try j.close('}');
}

fn plls(j: anytype, board: *Board) !void {
    const unit = &board.plls;
    try j.open("pll", '{');
    try pll(j, "pll1", unit.pll1);
    try pll(j, "pll2", unit.pll2);
    try j.field("main_oscillator_wait_code", unit.moscwtcr);
    try j.field("dropped_locked", unit.dropped_locked);
    try j.close('}');
}

fn pll(j: anytype, key: []const u8, unit: Config) !void {
    const mul = unit.multiplier();
    const outputs = unit.outputRatios();
    try j.open(key, '{');
    try j.field("configured", unit.configured());
    try j.field("source", unit.source().name());
    try j.field("input_ratio", unit.inputRatio());
    try j.field("multiplier_whole", mul.whole());
    try j.field("multiplier_hundredths", mul.hundredths());
    try j.field("p_ratio", outputs[0]);
    try j.field("q_ratio", outputs[1]);
    try j.field("r_ratio", outputs[2]);
    try j.field("dropped_running", unit.dropped_running);
    try j.field("prohibited_divider", unit.prohibited_divider);
    try j.close('}');
}

fn voltage(j: anytype, board: *Board) !void {
    const unit = &board.voltage;
    const watch = &board.brownout;
    try j.open("voltage", '{');
    try j.field("stores", unit.stores);
    try j.field("range", unit.range().name());
    try j.field("transitions", unit.transitions);
    try j.field("dropped_locked", unit.dropped_locked);
    try j.field("flag_writes", unit.flag_writes);
    try j.field("pll_selects_hazard", watch.brownouts);
    try j.field("pll_selects_safe", watch.lifts);
    try j.close('}');
}

fn lowPower(j: anytype, board: *Board) !void {
    const unit = &board.low_power;
    try j.open("low_power", '{');
    try j.field("stores", unit.stores);
    try j.field("lpscr", unit.lpscr);
    try j.field("wfi_state", if (unit.state()) |selected| selected.name() else null);
    try j.field("bus_output_kept", unit.busOutputKept());
    try j.field("io_kept", unit.ioKept());
    try j.field("soft_start", unit.softStart().name());
    try j.field("dropped_locked", unit.dropped_locked);
    try j.field("standby_selects", unit.standby_selects);
    try j.field("undefined_modes", unit.undefined_modes);
    try j.field("prohibited_softstart", unit.prohibited_softstart);
    try j.close('}');
}

fn monitors(j: anytype, board: *Board) !void {
    const unit = &board.monitors;
    try j.open("monitors", '{');
    try j.field("refused_filter_changes", unit.fields.filters);
    try j.field("refused_rise_bands", unit.bands.bands);
    try j.field("refused_negations", unit.bands.negations);
    try j.field("dropped_locked", unit.dropped);
    try j.open("channels", '[');
    for (&unit.channels, lvd.names, 0..) |*channel, label, index| {
        if (channel.quiet()) continue;
        try j.open(null, '{');
        try j.field("index", index);
        try j.field("name", label);
        try j.field("live", channel.live);
        try j.field("above", channel.above);
        try j.field("crossings", channel.crossings);
        try j.field("det", channel.det);
        try j.field("refused_clears", channel.refused_clears);
        try j.field("reserved_level", channel.reserved_level);
        try j.close('}');
    }
    try j.close(']');
    try j.close('}');
}
