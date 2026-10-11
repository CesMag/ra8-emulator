//! Window-scoped helpers the shell and the SDL backend share (RA8EMU-500,
//! RA8EMU-966): the still machinery and the size and full-screen key
//! arithmetic. The opener lives in src/interfaces/gui/main.zig, the one
//! place that links SDL; nothing else imports the backend, so a build
//! without -Dgui never compiles it or links SDL.
//! There is no unit test here: `zig build test` has no SDL.
//! The shell it shows is covered through the headless platform.
pub const still = @import("still.zig");
pub const stills = @import("stills.zig");
pub const size = @import("size.zig");
pub const keys = @import("keys.zig");
