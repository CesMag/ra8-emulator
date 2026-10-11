//! The `audio`, `mipi_phy` and `capture` objects of `--report json`
//! (RA8EMU-371): SSIE out, PDM in, the MIPI D-PHY under DSI and CSI, and
//! the CEU camera capture, the same facts report/audio.zig, mipi.zig and
//! capture.zig print. Every key is always present; the channel lists hold
//! only the channels the firmware touched.
const Board = @import("ra8_board").board.Board;
const ssie = @import("ra8_chip").periph.ssie;
const status = @import("ra8_chip").periph.mipi.phy.status;

/// The three objects, keyed inside the document after `graphics`.
pub fn section(j: anytype, board: *Board) !void {
    try audio(j, board);
    try mipi(j, &board.link);
    try capture(j, &board.capture);
}

fn audio(j: anytype, board: *Board) !void {
    try j.open("audio", '{');
    try j.open("ssie", '[');
    for (&board.audio.channels, 0..) |*unit, index| {
        if (unit.quiet()) continue;
        try j.open(null, '{');
        try j.field("channel", index);
        try j.field("transmitting", unit.transmitting());
        try j.field("receiving", unit.ssicr & 1 != 0);
        try j.field("transmitted", unit.transmitted);
        try j.field("last", unit.last);
        try j.field("staged", unit.staged());
        try j.field("fifo_depth", ssie.tx_depth);
        try j.field("dropped", unit.dropped());
        try j.field("discarded", unit.discarded());
        try j.field("resets", unit.resetCount());
        try j.field("refused_narrow", unit.refused());
        try j.close('}');
    }
    try j.close(']');
    try j.open("pdm", '[');
    for (&board.microphone.channels, 0..) |*unit, index| {
        if (unit.quiet()) continue;
        try j.open(null, '{');
        try j.field("channel", index);
        try j.field("running", unit.running);
        try j.field("read_enable", unit.read_enable);
        try j.field("read", unit.read);
        try j.field("last", unit.last);
        try j.field("waiting", unit.filled);
        try j.field("starved", unit.starved);
        try j.field("overrun", unit.overrun);
        try j.close('}');
    }
    try j.close(']');
    try j.close('}');
}

fn mipi(j: anytype, phy: anytype) !void {
    try j.open("mipi_phy", '{');
    try j.field("touched", !phy.quiet());
    try j.field("mode", phy.mode().name());
    try j.field("status", status.describe(phy.sfr()));
    try j.field("refclk_mhz", phy.referenceMhz());
    try j.field("power_ups", phy.powerups);
    try j.field("pll_locks", phy.locks);
    try j.field("flag_polls", phy.polls);
    try j.field("dark_polls", phy.dark_polls);
    try j.field("lane_enables", phy.enables);
    try j.field("early_enables", phy.early_enables);
    try j.field("ignored_pll_stores", phy.pll.ignored);
    try j.field("refused_sfr_stores", phy.refused);
    try j.close('}');
}

fn capture(j: anytype, camera: anytype) !void {
    try j.open("capture", '{');
    try j.field("arms", camera.arms);
    try j.field("frames", camera.frames);
    try j.field("last_width", camera.last_width);
    try j.field("last_lines", camera.last_lines);
    try j.field("last_bytes", camera.last_bytes);
    try j.field("declined", camera.declined);
    try j.field("last_decline", if (camera.last_decline) |why| @tagName(why) else null);
    try j.field("short_frames", camera.short_frames);
    try j.field("short_lines", camera.short_lines);
    try j.field("short_bytes", camera.short_bytes);
    try j.field("refused_fake_end", camera.faked);
    try j.close('}');
}
