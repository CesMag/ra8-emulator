//! ra8_gui: the RA8D2 board emulator's window (RA8EMU-1087, ADR 0004 step 6),
//! built only under -Dgui. `ra8_gui [flags] IMAGE` opens the docked debugger
//! shell (shell_main.zig) on the image in the SDL window (window.zig),
//! with the image's session served in-process. There is no second window
//! and no command-line run here (RA8EMU-1097): the run flags belong to
//! ra8_emulator, which never links SDL.
const std = @import("std");
const app = @import("gui_app");
const host = @import("ra8_host");
const gui_window = @import("window/window.zig");

// A macOS build carries the Info.plist the camera permission needs.
comptime {
    _ = host.camera.av_info_plist;
}

pub fn main(init: std.process.Init) !u8 {
    const allocator = init.arena.allocator();
    const argv = try init.minimal.args.toSlice(allocator);
    return app.shell.main.run(allocator, init.io, init.environ_map, argv, gui_window.opener);
}
