//! The SDL window ra8_gui opens (RA8EMU-646). src/interfaces/gui/main.zig
//! hands this opener to the shell (shell_main.run); nothing else imports
//! it, so a build without -Dgui never compiles it or links SDL.
//! It has no unit test: `zig build test` has no SDL.
//! The shell it shows is covered through the headless platform.
const gui = @import("gui_app");
const sdl = @import("gui_sdl");
pub const still = @import("still.zig");
pub const stills = @import("stills.zig");
pub const size = @import("size.zig");
pub const keys = @import("keys.zig");

const Platform = gui.platform.Platform;

/// The one window ra8_gui opens, alive from open until close.
var backend: ?sdl.Sdl = null;

pub const opener: gui.platform.Opener = .{ .open = open, .close = close };

fn open() ?Platform {
    backend = sdl.Sdl.init("ra8 emulator") catch return null;
    if (backend) |*window| return window.platform();
    return null;
}

fn close() void {
    if (backend) |*window| window.deinit();
    backend = null;
}
