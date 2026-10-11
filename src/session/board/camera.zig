//! Changing where the camera engine's pixels come from on a running board
//! (RA8EMU-795, RA8EMU-1114). The caller opens the host input, since the
//! session never opens a host file or device. This wraps the input as the
//! camera's frame source, which reads the sensor's FORMAT CONTROL byte at
//! each capture, and installs it where the CEU reads.
const std = @import("std");
const Board = @import("ra8_board").board.Board;
const camera_install = @import("ra8_board").camera_install;
const hosted = @import("ra8_components").camera.hosted;

/// Install `input` as `board`'s camera source: a host input the caller
/// opened, or null for the camera model's own gradient. The board owns the
/// input from here. On an error the input is closed and the old source
/// stays. Call it only on the thread that steps the board.
pub fn install(board: *Board, allocator: std.mem.Allocator, input: anytype) !void {
    const next = try hosted.wrap(allocator, input, &board.wire.sensor.format);
    camera_install.install(board, next);
}
