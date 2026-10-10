//! The voltage-monitor part of the end-of-run report.
//!
//! Its own file rather than a section inside report.zig, which sits at the
//! 400-line gate: the PVD lines are the block with the most to say when
//! something is wrong, and they kept growing.
const std = @import("std");

const Board = @import("../../../board/board.zig").Board;
const lvd = @import("ra8_chip").periph.lvd;

const Writer = *std.Io.Writer;

/// One line per voltage monitor the firmware programmed. A monitor whose
/// threshold sits over the rail is reported as below, which is the reading
/// the C tree cannot give: there every PVDmSR read says the rail is fine.
pub fn sections(board: *Board, out: Writer) !void {
    if (board.monitors.quiet()) return;
    for (&board.monitors.channels, lvd.names) |*channel, label| {
        if (channel.quiet()) continue;
        try out.print("{s}: {s}", .{ label, monitorState(channel) });
        if (channel.crossings != 0) {
            try out.print(", {d} crossing(s), DET={d}", .{ channel.crossings, @intFromBool(channel.det) });
        }
        if (channel.refused_clears != 0) {
            try out.print(", {d} DET CLEAR(S) WRITTEN AS A 1 AND REFUSED", .{channel.refused_clears});
        }
        if (channel.reserved_level != 0) {
            try out.print(", {d} RESERVED PVDLVL ENCODING(S)", .{channel.reserved_level});
        }
        try out.print("\n", .{});
    }
    if (board.monitors.fields.filters != 0) {
        try out.print(
            "SYSC-PVD: REFUSED {d} FSAMP change(s) made with the digital filter running, set DFDIS first\n",
            .{board.monitors.fields.filters},
        );
    }
    if (board.monitors.bands.bands != 0) {
        try out.print(
            "SYSC-PVD: REFUSED {d} RHSEL=1 store(s) made with PVDmCR0.RI clear, arm the reset path before selecting the rise-detect band\n",
            .{board.monitors.bands.bands},
        );
    }
    if (board.monitors.bands.negations != 0) {
        try out.print(
            "SYSC-PVD: REFUSED {d} RN=1 store(s) made with PVDmFCR.RHSEL set, that combination is prohibited\n",
            .{board.monitors.bands.negations},
        );
    }
    if (board.monitors.dropped != 0) {
        try out.print(
            "SYSC-PVDLR: DROPPED {d} write(s) to PVD4/PVD5 with LOCK set (write 0 to PVDLR once to release it)\n",
            .{board.monitors.dropped},
        );
    }
}

/// What the comparator is saying right now, in the words the report uses.
fn monitorState(channel: *const lvd.Channel) []const u8 {
    if (!channel.live) return "monitor off";
    return if (channel.above) "VCC above Vdet" else "VCC BELOW Vdet";
}
