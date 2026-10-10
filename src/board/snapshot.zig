//! The snapshot of a whole board and run, as `ra8_board.snapshot`
//! (RA8EMU-1023): the board's walk, the run file, what the run owed its
//! clocks, and the sections that save a board-level structure or mix
//! on-chip blocks with fitted parts. The index file for src/board/snapshot.
pub const board = @import("snapshot/board.zig");
pub const memory = @import("snapshot/memory.zig");
pub const rswitch = @import("snapshot/rswitch.zig");
pub const run = @import("snapshot/run.zig");
pub const sd = @import("snapshot/sd.zig");
pub const storage = @import("snapshot/storage.zig");
pub const stretch = @import("snapshot/stretch.zig");
pub const usb = @import("snapshot/usb.zig");
pub const wire = @import("snapshot/wire.zig");
pub const wired = @import("snapshot/wired.zig");
