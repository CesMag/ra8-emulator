//! The camera-capture part of the end-of-run report.
//!
//! The line answers the one question the capture path can be wrong about:
//! did a frame actually land in the firmware's buffer, or did the run only
//! ask for one. It ends with the source the frame came from (RA8EMU-538).
const std = @import("std");

const Board = @import("ra8_board").board.Board;

const Writer = *std.Io.Writer;

/// Quiet unless the run armed a capture. The declined arm and the refused
/// store are the loud cases: CETCR.CPE is what the engine raised, so an
/// image that wrote it was claiming a frame it never captured.
pub fn sections(board: *Board, out: Writer) !void {
    const camera = &board.capture;
    if (camera.quiet()) return;
    const source = camera.source;
    const gap: []const u8 = if (source.detail.len == 0) "" else " ";
    try out.print("CEU: {d} arm(s), {d} frame(s), last {d}x{d} ({d} bytes) {s}{s}{s}\n", .{
        camera.arms,       camera.frames, camera.last_width, camera.last_lines,
        camera.last_bytes, source.label,  gap,               source.detail,
    });
    if (camera.last_decline) |reason| {
        try out.print(
            "CEU: {d} arm(s) captured nothing, last because the capture was {s}\n",
            .{ camera.declined, @tagName(reason) },
        );
    }
    if (camera.short_frames != 0) {
        try out.print(
            "CEU: {d} capture(s) CUT SHORT by memory, {d} whole line(s) / {d} byte(s) had already reached the buffer\n",
            .{ camera.short_frames, camera.short_lines, camera.short_bytes },
        );
    }
    if (camera.faked != 0) {
        try out.print(
            "CEU: REFUSED {d} store(s) to CETCR, firmware cannot raise a capture-end flag itself\n",
            .{camera.faked},
        );
    }
}
