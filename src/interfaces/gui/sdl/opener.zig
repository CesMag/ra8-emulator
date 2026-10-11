//! The SDL window ra8_gui opens (RA8EMU-646). src/interfaces/gui/main.zig
//! hands this opener to the shell (shell/main.zig). It is part of gui_sdl,
//! the one module that links SDL, so a build without -Dgui never compiles
//! it (RA8EMU-1162).
//! It has no unit test: `zig build test` has no SDL.
//! The shell it shows is covered through the headless platform.
const gui = @import("gui_app");
const Sdl = @import("sdl.zig").Sdl;

/// The one window ra8_gui opens, alive from open until close.
var backend: ?Sdl = null;

pub const opener: gui.platform.Opener = .{ .open = open, .close = close };

fn open() ?gui.platform.Platform {
    backend = Sdl.init("ra8 emulator") catch return null;
    if (backend) |*window| return window.platform();
    return null;
}

fn close() void {
    if (backend) |*window| window.deinit();
    backend = null;
}
