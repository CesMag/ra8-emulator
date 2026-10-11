//! The `serial` object of `--report json` (RA8EMU-360): the SCI channels,
//! the console line, the SPI channels and the SEGGER RTT ring, the same
//! facts report/serial.zig prints. Every key is always present; channel
//! lists hold only the channels that did anything. The USB host lines that
//! also live in serial.zig belong to the usb batch and are left out here.
const Board = @import("ra8_board").board.Board;

/// The whole `serial` object, keyed inside the document.
pub fn section(j: anytype, board: *Board) !void {
    try j.open("serial", '{');
    try sci(j, board);
    try j.open("console", '{');
    try j.field("lines", board.serial.line.lines);
    try j.field("last", if (board.serial.line.lines != 0) board.serial.line.slice() else null);
    try j.close('}');
    try spi(j, board);
    try rtt(j, board);
    try j.close('}');
}

fn sci(j: anytype, board: *Board) !void {
    try j.open("sci", '[');
    for (&board.serial.channels, 0..) |*channel, index| {
        if (channel.quiet()) continue;
        try j.open(null, '{');
        try j.field("index", index);
        try j.field("transmitted", channel.transmitted);
        try j.field("received", channel.received);
        try j.field("rx_dropped", channel.rx.dropped);
        try j.field("unsent_te_clear", channel.unsent);
        try j.field("refused_status_stores", channel.status_stores);
        try j.field("overruns", channel.errors.overruns);
        try j.field("overrun_standing", channel.errors.overrun);
        try j.field("refused_unnamed_reads", channel.unnamed_reads);
        try j.field("refused_unnamed_stores", channel.unnamed_stores);
        try j.field("idle_frames", channel.idle_frames);
        try j.open("lin", '{');
        try j.field("breaks", channel.lin.breaks);
        try j.field("break_length", channel.lin.length());
        try j.field("refused_unenabled", channel.lin.unenabled);
        try j.field("refused_status_stores", channel.lin.status_stores);
        try j.close('}');
        try j.close('}');
    }
    try j.close(']');
}

fn spi(j: anytype, board: *Board) !void {
    try j.open("spi", '[');
    for (&board.spi.channels, 0..) |*unit, index| {
        if (unit.quiet()) continue;
        try j.open(null, '{');
        try j.field("index", index);
        try j.field("enabled", unit.enabled());
        try j.field("frames", unit.frames);
        try j.field("last", unit.last);
        try j.field("loopback", unit.loopback());
        try j.field("width", unit.width);
        try j.field("lsb_first", unit.frameOf().lsb_first);
        try j.field("unnamed_width_frames", unit.unnamed);
        try j.field("refused_spe_clear", unit.refused);
        try j.field("starved_reads", unit.starved);
        try j.field("refused_narrow_writes", unit.narrow_writes);
        try j.field("ignored_running_spcr2", unit.locked.ignored);
        try j.field("refused_narrow_reads", unit.narrow_reads);
        try j.close('}');
    }
    try j.close(']');
}

fn rtt(j: anytype, board: *Board) !void {
    const probe = &board.trace;
    const pending = probe.line.pending();
    try j.open("rtt", '{');
    try j.field("control_block", probe.found);
    try j.field("drained", probe.drained);
    try j.field("lines", probe.line.lines);
    try j.field("last", if (probe.line.lines != 0) probe.line.slice() else null);
    try j.field("pending", if (pending.len != 0) pending else null);
    try j.field("cut_lines", probe.line.wrapped);
    try j.field("refused_off_ram", probe.off_ram);
    try j.field("forgotten", probe.forgotten);
    try j.close('}');
}
