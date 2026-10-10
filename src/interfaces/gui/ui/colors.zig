//! The GUI's one palette (RA8EMU-1082, ADR 0004 cleanup): every chrome colour
//! the shell, the bars and the panes paint, as named roles. Files under
//! src/interfaces/gui read from here instead of writing their own
//! Color.rgb literals; tests/interfaces/gui/ui/colors_test.zig keeps it that
//! way. The board picture (src/interfaces/render/board_view.zig), the LCD image and
//! colours computed from data are not chrome and stay where they are.
const draw_list = @import("ra8_render").draw_list;

const Color = draw_list.Color;
const palette = @This();

pub const background = Color.rgb(0x21, 0x25, 0x2B);
pub const preview = Color.rgb(0x28, 0x2C, 0x34);
pub const border = Color.rgb(0x4A, 0x51, 0x5C);
pub const ink = Color.rgb(0xD8, 0xDE, 0xE9);
pub const muted = Color.rgb(0x9A, 0xA5, 0xB4);
pub const face = Color.rgb(0x2C, 0x31, 0x3A);
pub const pressed_face = Color.rgb(0x5C, 0x63, 0x70);
pub const button_face = Color.rgb(0x4C, 0x56, 0x6A);
pub const selected_face = Color.rgb(0x3B, 0x42, 0x52);
pub const well = Color.rgb(0x1B, 0x1F, 0x24);
pub const gutter = Color.rgb(0x18, 0x1A, 0x1F);
pub const black = Color.rgb(0x00, 0x00, 0x00);
pub const led_off = Color.rgb(0x3A, 0x40, 0x4A);
/// The band behind the current line, the top frame and the field being edited.
pub const band = Color.rgb(0x2F, 0x3B, 0x4C);
/// Text on that band, and a value that just changed.
pub const highlight = Color.rgb(0xE5, 0xC0, 0x7B);
pub const fitted_band = Color.rgb(0x2E, 0x4A, 0x3A);
pub const accent = Color.rgb(0x61, 0xAF, 0xEF);
pub const bad = Color.rgb(0xE0, 0x6C, 0x75);
pub const good = Color.rgb(0x98, 0xC3, 0x79);
pub const recording = Color.rgb(0xE0, 0x3C, 0x31);

/// The status strip's tones.
pub const tone = struct {
    pub const waiting = muted;
    pub const good = palette.good;
    pub const bad = palette.bad;
    pub const running = palette.accent;
    pub const halted = palette.highlight;
};

/// Marker hues for camera sources and the camera permission buttons.
pub const hue = struct {
    pub const blue = Color.rgb(0x5E, 0x81, 0xAC);
    pub const purple = Color.rgb(0xB4, 0x8E, 0xAD);
    pub const green = Color.rgb(0xA3, 0xBE, 0x8C);
    pub const yellow = Color.rgb(0xEB, 0xCB, 0x8B);
    pub const red = Color.rgb(0xBF, 0x61, 0x6A);
};
