//! Changing where the CEU's pixels come from on a running board
//! (RA8EMU-795): the application opens the new source first (RA8EMU-1011),
//! then this closes the old source and puts the new one where the CEU
//! reads. A source that cannot be opened never gets here, so the old one
//! stays in place.
const Board = @import("board.zig").Board;
const frame_source = @import("ra8_chip").periph.frame_source;

/// Install `next` as `board`'s camera source; the board owns it from here.
/// Call it only on the thread that steps the board.
pub fn install(board: *Board, next: frame_source.FrameSource) void {
    board.capture.source.close();
    board.capture.source = next;
}
