//! The one SDL3 C import of the gui_sdl module, shared by its files so they
//! all see the same SDL types. build.zig translates SDL3/SDL.h into the
//! `sdl3` module with the translate-c package.
pub const c = @import("sdl3");
