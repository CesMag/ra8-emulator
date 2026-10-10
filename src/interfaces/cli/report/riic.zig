//! The RIIC controller's own lines in the end-of-run report: what each
//! channel clocked, what it refused, and what its responder half answered.
//! The parts sitting on the bus report themselves from network.zig.
const Board = @import("ra8_board").board.Board;
const Writer = @import("../report.zig").Writer;

/// One line per RIIC channel that saw traffic. A transfer clocked with the
/// interface still disabled, a START on a bus that was already busy, a byte
/// written with no transaction open, a byte written before the restart
/// condition had been issued, an ACKBT moved without its write-enable in
/// force and a read past what the device had to say are all things dev
/// answered anyway, so each is reported apart from the transfers that
/// completed.
pub fn channels(board: *Board, out: Writer) !void {
    const unit = &board.wire.controller;
    if (board.wire.quiet()) return;
    for (&unit.channels, 0..) |*channel, index| {
        if (channel.quiet()) continue;
        try out.print(
            "RIIC{d}: {d} transfer(s), {d} byte(s) out, {d} byte(s) in, {d} address(es) NACKed",
            .{ index, channel.transfers, channel.sent, channel.received, channel.nacks },
        );
        if (channel.uninit != 0) {
            try out.print(", {d} ACCESS(ES) WITH THE INTERFACE DISABLED", .{channel.uninit});
        }
        if (channel.held != 0) {
            try out.print(", {d} BUS ACCESS(ES) WHILE HELD IN RESET", .{channel.held});
        }
        if (channel.st_busy != 0) {
            try out.print(", {d} START(S) ON A BUSY BUS REFUSED", .{channel.st_busy});
        }
        if (channel.rs_idle != 0) {
            try out.print(", {d} REPEATED START(S) WITH NOTHING TO REPEAT", .{channel.rs_idle});
        }
        if (channel.restart.dropped != 0) {
            try out.print(
                ", {d} WRITE(S) DROPPED WITH THE RESTART STILL IN FLIGHT",
                .{channel.restart.dropped},
            );
        }
        if (channel.stop.deferred != 0) {
            try out.print(
                ", {d} STOP(S) ASKED FOR WITH THE FRAME STILL RUNNING",
                .{channel.stop.deferred},
            );
        }
        if (channel.ack.protected != 0) {
            try out.print(
                ", {d} ACKBT STORE(S) WITH ACKWP NOT YET IN FORCE",
                .{channel.ack.protected},
            );
        }
        if (channel.no_start != 0) {
            try out.print(", {d} DATA WRITE(S) WITH NO TRANSACTION OPEN", .{channel.no_start});
        }
        if (channel.rx.overread != 0) {
            try out.print(", {d} READ(S) PAST WHAT THE DEVICE HAD TO SAY", .{channel.rx.overread});
        }
        try out.print("\n", .{});
        if (channel.target.cycles != 0 or channel.target.unaddressed != 0) {
            try out.print(
                "RIIC{d} target: own 0x{X:0>2}, {d} controller write+read cycle(s), echo {s}",
                .{
                    index,
                    @as(u8, channel.target.own_address),
                    channel.target.cycles,
                    if (channel.target.mismatched) "MISMATCHED" else "matched",
                },
            );
            if (channel.target.nacked != 0) {
                try out.print(", {d} read frame(s) the controller NACKed to an end", .{channel.target.nacked});
            }
            if (channel.target.unaddressed != 0) {
                try out.print(", {d} ARMING(S) WITH NO OWN ADDRESS REFUSED", .{channel.target.unaddressed});
            }
            try out.print("\n", .{});
        }
    }
}
