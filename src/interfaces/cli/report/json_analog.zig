//! The `analog` object of `--report json` (RA8EMU-373): the DAC_B channels,
//! the ADC_B converter and the ACMPHS comparators, the same facts
//! report/analog.zig prints. Every key is always present; the channel lists
//! hold only the channels the firmware touched.
const Board = @import("ra8_board").board.Board;

/// The `analog` object, keyed inside the document after `backup`.
pub fn section(j: anytype, board: *Board) !void {
    try j.open("analog", '{');
    try dac(j, board);
    try adc(j, &board.adc);
    try comparators(j, board);
    try j.close('}');
}

fn dac(j: anytype, board: *Board) !void {
    try j.open("dac", '[');
    for (&board.analog.channels, 0..) |*unit, index| {
        if (unit.quiet()) continue;
        try j.open(null, '{');
        try j.field("channel", index);
        try j.field("outputs", unit.outputs);
        try j.field("last", unit.code());
        try j.field("peak", unit.peak);
        try j.field("state", if (unit.driving()) "driving" else if (unit.enabled()) "output disabled" else "disabled");
        try j.field("dark", unit.dark);
        try j.field("blocked", unit.blocked);
        try j.field("above_data", unit.above_data);
        try j.field("placement", unit.placement().name());
        try j.close('}');
    }
    try j.close(']');
}

fn adc(j: anytype, unit: anytype) !void {
    try j.open("adc", '{');
    try j.field("scans", unit.scans);
    try j.field("converted", unit.converted);
    try j.field("last_code", unit.last_code);
    try j.field("refused_disabled", unit.refused_disabled);
    try j.field("refused_fake_results", unit.faked);
    try j.field("empty_scans", unit.empty);
    try j.field("unbacked", unit.unbacked);
    try j.field("stops", unit.stops);
    try j.field("masked", unit.masked);
    try j.close('}');
}

fn comparators(j: anytype, board: *Board) !void {
    try j.open("comparators", '[');
    for (&board.comparators.channels, 0..) |*unit, index| {
        if (unit.quiet()) continue;
        try j.open(null, '{');
        try j.field("channel", index);
        try j.field("operating", unit.operating());
        try j.field("polls", unit.polls);
        try j.field("inverted", unit.inverted());
        try j.field("edge", unit.edge().name());
        try j.field("dark_polls", unit.dark_polls);
        try j.field("refused", unit.refused);
        try j.close('}');
    }
    try j.close(']');
}
