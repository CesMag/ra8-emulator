//! The keys that toggle full screen (RA8EMU-966): Ctrl+Cmd+F on macOS,
//! matching the system's own full-screen shortcut, and F11 elsewhere. And
//! the modifier a shortcut is held with (RA8EMU-959): Cmd on macOS, Ctrl
//! elsewhere. The SDL backend asks both before passing a key to the shell,
//! so the choices are host-tested without SDL. Codes are SDL keycodes.

/// SDLK_F11 and SDLK_F.
pub const f11: u32 = 0x4000_0044;
pub const letter_f: u32 = 'f';

/// The modifier keys held with a key press.
pub const Mods = struct {
    ctrl: bool = false,
    gui: bool = false,
    alt: bool = false,
    shift: bool = false,
};

/// Whether `mods` hold this OS's shortcut modifier and not the other OS's:
/// Cmd on macOS, Ctrl elsewhere. Shift may ride along; the chord's own key
/// says whether that matters.
pub fn primary(mods: Mods, mac: bool) bool {
    if (mods.alt) return false;
    return if (mac) mods.gui and !mods.ctrl else mods.ctrl and !mods.gui;
}

/// Whether pressing `key` with `mods` toggles full screen on this OS.
pub fn togglesFullscreen(key: u32, mods: Mods, mac: bool) bool {
    if (mods.alt or mods.shift) return false;
    if (mac) return key == letter_f and mods.ctrl and mods.gui;
    return key == f11 and !mods.ctrl and !mods.gui;
}
