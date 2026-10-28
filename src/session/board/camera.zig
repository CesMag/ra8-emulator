//! Changing where the camera engine's pixels come from on a running board
//! (RA8EMU-795, RA8EMU-1114). The caller opens the host input, since the
//! session never opens a host file or device. This wraps the input as the
//! camera's frame source, which reads the sensor's FORMAT CONTROL byte at
//! each capture, and installs it where the CEU reads.
const std = @import("std");
const Board = @import("ra8_board").board.Board;
const camera_install = @import("ra8_board").camera_install;
const hosted = @import("ra8_components").camera.hosted;
const FrameSource = @import("ra8_chip").periph.frame_source.FrameSource;
pub const Preview = @import("ra8_chip").periph.frame_source.Preview;

/// Install `input` as `board`'s camera source: a host input the caller
/// opened, or null for the camera model's own gradient. The board owns the
/// input from here. On an error the input is closed and the old source
/// stays. Call it only on the thread that steps the board.
pub fn install(board: *Board, allocator: std.mem.Allocator, input: anytype) !void {
    set(board, try source(board, allocator, input));
}

/// The frame source for `input` (null: the gradient), not yet installed. It
/// owns `input`, closed on an error.
pub fn source(board: *Board, allocator: std.mem.Allocator, input: anytype) !FrameSource {
    return hosted.wrap(allocator, input, &board.wire.sensor.format);
}

/// Makes `next` the board's camera source and closes the old one. Cannot
/// fail, so a caller that built `next` in steps swaps only when all worked.
pub fn set(board: *Board, next: FrameSource) void {
    camera_install.install(board, next);
}

/// Read an RGB preview frame from the installed camera source, if available (RA8EMU-1180).
pub fn preview(board: *Board) ?Preview {
    return board.capture.source.preview();
}
