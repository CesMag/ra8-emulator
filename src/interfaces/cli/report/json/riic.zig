//! The `riic` array of `--report json` (RA8EMU-360): one entry per RIIC
//! channel that saw traffic, with its responder half, the same facts
//! report/riic.zig prints. Every key is always present in an entry.
const Board = @import("ra8_board").board.Board;

/// The whole `riic` array, keyed inside the document.
pub fn section(j: anytype, board: *Board) !void {
    try j.open("riic", '[');
    for (&board.wire.controller.channels, 0..) |*channel, index| {
        if (channel.quiet()) continue;
        try j.open(null, '{');
        try j.field("index", index);
        try j.field("transfers", channel.transfers);
        try j.field("sent", channel.sent);
        try j.field("received", channel.received);
        try j.field("nacks", channel.nacks);
        try j.field("disabled_accesses", channel.uninit);
        try j.field("held_in_reset", channel.held);
        try j.field("refused_busy_starts", channel.st_busy);
        try j.field("idle_restarts", channel.rs_idle);
        try j.field("dropped_mid_restart", channel.restart.dropped);
        try j.field("deferred_stops", channel.stop.deferred);
        try j.field("ackbt_unprotected", channel.ack.protected);
        try j.field("writes_no_start", channel.no_start);
        try j.field("overreads", channel.rx.overread);
        const target = &channel.target;
        try j.open("target", '{');
        try j.field("own_address", @as(u8, target.own_address));
        try j.field("cycles", target.cycles);
        try j.field("mismatched", target.mismatched);
        try j.field("nacked_reads", target.nacked);
        try j.field("refused_unaddressed", target.unaddressed);
        try j.close('}');
        try j.close('}');
    }
    try j.close(']');
}
