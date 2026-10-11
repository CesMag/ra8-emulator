//! Window-scoped helpers the shell and the SDL backend share (RA8EMU-500,
//! RA8EMU-966): the still machinery and the size and full-screen key
//! arithmetic. The opener lives in sdl/opener.zig, inside gui_sdl, the one
//! module that links SDL, so a build without -Dgui never compiles it.
pub const still = @import("still.zig");
pub const stills = @import("stills.zig");
pub const size = @import("size.zig");
pub const keys = @import("keys.zig");
