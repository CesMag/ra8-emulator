//! The board memory-configuration sweep (RA8EMU-645), as `ra8_board.sizing`.
//! The index file for src/board/sizing.
pub const matrix = @import("sizing/matrix.zig");
pub const sweep = @import("sizing/sweep.zig");
pub const workload = @import("sizing/workload.zig");
