//! ra8_render: board-view composition and image/audio encoders for CLI
//! capture. Every encoder writes to a writer supplied by its caller;
//! there is no windowing or native widget renderer.
pub const board_view = @import("board_view.zig");
pub const png = @import("png.zig");
pub const gif = @import("gif/gif.zig");
pub const wav = @import("wav.zig");
