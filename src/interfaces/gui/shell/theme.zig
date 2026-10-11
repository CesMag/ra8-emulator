//! The shell's theme (RA8EMU-961, RA8EMU-962, RA8EMU-1165): the palette
//! the window paints with, whether it follows the OS, and the picker on the
//! status strip that changes it while the window is up. The picker itself
//! (gui/ui/theme_picker.zig) only lays out, paints and hit-tests. The choice
//! it shows is read from what is being painted with, never kept beside it,
//! so the icon cannot disagree with the theme in use.
const draw_list = @import("ra8_render").draw_list;
const platform = @import("../platform.zig");
const colors = @import("../ui/colors.zig");
const theme_picker = @import("../ui/theme_picker.zig");
const codes = @import("../ui/hex_entry.zig").codes;

const Rect = draw_list.Rect;

pub const Themes = struct {
    /// The palette every leaf, bar and strip paints with.
    active: *const colors.Theme = colors.of(.dark),
    /// Repaint `active` from the OS appearance (RA8EMU-962): read before
    /// the next frame is drawn and again whenever the OS reports a change.
    follow_os: bool = false,
    /// The OS appearance has been read since the choice was made.
    styled: bool = false,
    /// The picker's popover is out.
    open: bool = false,

    /// The choice in force: System while following the OS, else the palette
    /// the window is pinned to.
    pub fn choice(self: *const Themes) colors.Choice {
        if (self.follow_os) return .system;
        return if (self.active == &colors.palettes.light) .light else .dark;
    }

    /// Paint with `picked` from here on. System paints Light until the OS
    /// has been read, which `restyle` does before the next frame is drawn.
    pub fn choose(self: *Themes, picked: colors.Choice) void {
        self.follow_os = picked == .system;
        self.active = colors.of(picked);
        self.styled = false;
    }

    /// Take the palette from the OS appearance `os` when following it; an
    /// OS with no answer gets Light.
    pub fn restyle(self: *Themes, os: platform.Appearance) void {
        self.styled = true;
        if (!self.follow_os) return;
        self.active = colors.resolve(.system, os == .dark);
    }

    pub fn view(self: *const Themes) theme_picker.View {
        return .{ .choice = self.choice(), .open = self.open };
    }

    /// A left press at (`x`, `y`) with the status strip drawn in `strip`.
    /// The icon opens the popover and closes it again; a row chooses its
    /// theme and closes it; a press anywhere else closes it and goes no
    /// further. Returns whether the picker took the press.
    pub fn press(self: *Themes, strip: Rect, x: i32, y: i32) bool {
        const found = theme_picker.hit(strip, self.open, x, y) orelse {
            if (!self.open) return false;
            self.open = false;
            return true;
        };
        switch (found) {
            .button => self.open = !self.open,
            .row => |picked| {
                self.open = false;
                self.choose(picked);
            },
        }
        return true;
    }

    /// Escape closes the popover and changes nothing. Returns whether the
    /// event was taken.
    pub fn key(self: *Themes, event: platform.Event) bool {
        if (!self.open) return false;
        switch (event) {
            .key => |pressed| if (pressed.down and pressed.code == codes.escape) {
                self.open = false;
                return true;
            },
            else => {},
        }
        return false;
    }
};
